defmodule Aiur.CurrentRunMembership.Store.TerminalVerification do
  @moduledoc false

  alias Aiur.CurrentRunMembership.Event.Codec
  alias Aiur.CurrentRunMembership.Store.FileOps
  alias Aiur.TrackerIdentity

  @record_keys ~w(pending_keys run_id version)
  @version 1
  @unqualified_observation_key "unqualified_terminal_observation"

  @spec load(String.t(), String.t()) :: {:ok, MapSet.t(String.t())} | {:error, atom()}
  def load(path, run_id) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, MapSet.new()}

      {:ok, %File.Stat{type: :regular, size: size}} ->
        if size <= Codec.max_recovery_record_bytes() do
          load_regular_marker(path, run_id)
        else
          {:error, :terminal_verification_marker_too_large}
        end

      _ ->
        {:error, :terminal_verification_marker_invalid}
    end
  end

  @spec pending_key(TrackerIdentity.t()) :: {:ok, String.t()} | {:error, :invalid_identity}
  def pending_key(%TrackerIdentity{} = identity) do
    if TrackerIdentity.joinable?(identity) do
      key = {String.downcase(identity.owner), String.downcase(identity.repository), identity.provider_id}
      {:ok, key |> :erlang.term_to_binary([:deterministic]) |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)}
    else
      {:error, :invalid_identity}
    end
  end

  def pending_key(_identity) do
    {:ok,
     @unqualified_observation_key
     |> then(&:crypto.hash(:sha256, &1))
     |> Base.encode16(case: :lower)}
  end

  @spec pending?(MapSet.t(String.t())) :: boolean()
  def pending?(pending_keys), do: MapSet.size(pending_keys) > 0

  @spec write(String.t(), String.t(), MapSet.t(String.t()), (-> term())) :: :ok | {:error, term()}
  def write(path, run_id, pending_keys, sync_fun) when is_struct(pending_keys, MapSet) do
    if MapSet.size(pending_keys) == 0 do
      with :ok <- remove_marker(path), do: FileOps.sync_recovery_entry(sync_fun)
    else
      record = %{"version" => @version, "run_id" => run_id, "pending_keys" => pending_keys |> MapSet.to_list() |> Enum.sort()}

      with :ok <- Codec.validate_recovery_record_size(record),
           {:ok, contents} <- Jason.encode(record),
           :ok <- FileOps.atomic_write(path, contents),
           :ok <- FileOps.ensure_regular_file(path) do
        FileOps.sync_recovery_entry(sync_fun)
      end
    end
  end

  defp load_regular_marker(path, run_id) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"run_id" => ^run_id, "version" => @version, "pending_keys" => pending_keys} = record} <- Jason.decode(contents),
         @record_keys <- record |> Map.keys() |> Enum.sort(),
         true <- valid_pending_keys?(pending_keys) do
      {:ok, MapSet.new(pending_keys)}
    else
      _ -> {:error, :terminal_verification_marker_invalid}
    end
  end

  defp valid_pending_keys?(pending_keys) when is_list(pending_keys) do
    Enum.uniq(pending_keys) == pending_keys and Enum.all?(pending_keys, &valid_pending_key?/1)
  end

  defp valid_pending_keys?(_pending_keys), do: false
  defp valid_pending_key?(key) when is_binary(key), do: byte_size(key) == 64 and key =~ ~r/\A[0-9a-f]+\z/
  defp valid_pending_key?(_key), do: false

  defp remove_marker(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> File.rm(path)
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end
end
