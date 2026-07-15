defmodule Aiur.CurrentRunMembership.Event.Codec do
  @moduledoc false

  alias Aiur.TrackerIdentity

  @version 1
  @lifecycles [:queued, :retrying, :allocated, :running, :paused, :waiting, :replaced, :completed, :cancelled]
  @sources [:status_report, :tracker]
  @record_keys ~w(checksum identity lifecycle observed_at run_id source version)
  @identity_record_keys ~w(database_id identifier kind owner provider_id reason repository status version)
  @max_identity_scalar_bytes 512
  @max_checksum_bytes 128
  @max_recovery_record_bytes 4_096
  @max_journal_bytes 4_000_000
  @max_checkpoint_bytes 4_000_000

  @spec max_recovery_record_bytes() :: pos_integer()
  def max_recovery_record_bytes, do: @max_recovery_record_bytes

  @spec max_journal_bytes() :: pos_integer()
  def max_journal_bytes, do: @max_journal_bytes

  @spec max_checkpoint_bytes() :: pos_integer()
  def max_checkpoint_bytes, do: @max_checkpoint_bytes

  @spec validate_attributes(term(), term(), term(), term(), term()) :: :ok | {:error, atom()}
  def validate_attributes(run_id, identity, lifecycle, source, observed_at) do
    with :ok <- valid_run_id(run_id),
         :ok <- valid_identity(identity),
         :ok <- valid_lifecycle(lifecycle),
         :ok <- valid_source(source) do
      valid_observed_at(observed_at)
    end
  end

  @spec validate_recovery_record_size(map()) :: :ok | {:error, :record_too_large}
  def validate_recovery_record_size(record) when is_map(record) do
    validate_encoded_size(record, @max_recovery_record_bytes)
  end

  @spec validate_checkpoint_record_size(map()) :: :ok | {:error, :record_too_large}
  def validate_checkpoint_record_size(record) when is_map(record) do
    validate_encoded_size(record, @max_checkpoint_bytes)
  end

  @spec from_record(term()) ::
          {:ok,
           %{
             run_id: String.t(),
             identity: TrackerIdentity.t(),
             lifecycle: atom(),
             source: atom(),
             observed_at: DateTime.t(),
             checksum: String.t()
           }}
          | {:error, atom()}
  def from_record(record) when is_map(record) do
    with @record_keys <- record |> Map.keys() |> Enum.sort(),
         @version <- Map.get(record, "version"),
         :ok <- valid_run_id(Map.get(record, "run_id")),
         {:ok, identity} <- identity_from_record(Map.get(record, "identity")),
         {:ok, lifecycle} <- parse_lifecycle(Map.get(record, "lifecycle")),
         {:ok, source} <- parse_source(Map.get(record, "source")),
         {:ok, observed_at} <- parse_observed_at(Map.get(record, "observed_at")),
         checksum = Map.get(record, "checksum"),
         :ok <- valid_checksum(checksum),
         :ok <- validate_recovery_record_size(record) do
      {:ok,
       %{
         run_id: Map.get(record, "run_id"),
         identity: identity,
         lifecycle: lifecycle,
         source: source,
         observed_at: observed_at,
         checksum: checksum
       }}
    else
      _ -> {:error, :invalid_record}
    end
  end

  def from_record(_record), do: {:error, :invalid_record}

  @spec identity_record(TrackerIdentity.t()) :: map()
  def identity_record(%TrackerIdentity{} = identity) do
    %{
      "version" => identity.version,
      "status" => Atom.to_string(identity.status),
      "kind" => Atom.to_string(identity.kind),
      "owner" => identity.owner,
      "repository" => identity.repository,
      "provider_id" => identity.provider_id,
      "database_id" => identity.database_id,
      "identifier" => identity.identifier,
      "reason" => identity.reason
    }
  end

  defp valid_run_id(run_id) when is_binary(run_id) and byte_size(run_id) in 1..512 do
    if run_id == String.trim(run_id), do: :ok, else: {:error, :invalid_run_id}
  end

  defp valid_run_id(_run_id), do: {:error, :invalid_run_id}

  defp valid_identity(%TrackerIdentity{} = identity) do
    with true <- TrackerIdentity.joinable?(identity),
         :ok <- valid_identity_scalar(identity.owner),
         :ok <- valid_identity_scalar(identity.repository),
         :ok <- valid_identity_scalar(identity.provider_id),
         :ok <- valid_database_id(identity.database_id),
         :ok <- valid_identity_scalar(identity.identifier) do
      :ok
    else
      false -> {:error, :unjoinable_identity}
      {:error, _reason} -> {:error, :identity_too_large}
    end
  end

  defp valid_identity(_identity), do: {:error, :unjoinable_identity}

  defp valid_identity_scalar(value) when is_binary(value) and byte_size(value) in 1..@max_identity_scalar_bytes,
    do: :ok

  defp valid_identity_scalar(_value), do: {:error, :identity_too_large}

  defp valid_database_id(nil), do: :ok
  defp valid_database_id(value) when is_integer(value) and value > 0, do: :ok
  defp valid_database_id(_value), do: {:error, :invalid_database_id}

  defp valid_checksum(value) when is_binary(value) and byte_size(value) in 1..@max_checksum_bytes, do: :ok
  defp valid_checksum(_value), do: {:error, :invalid_checksum}
  defp valid_lifecycle(lifecycle), do: if(lifecycle in @lifecycles, do: :ok, else: {:error, :invalid_lifecycle})
  defp valid_source(source), do: if(source in @sources, do: :ok, else: {:error, :invalid_source})
  defp valid_observed_at(%DateTime{utc_offset: 0, std_offset: 0}), do: :ok
  defp valid_observed_at(_observed_at), do: {:error, :invalid_observed_at}

  defp validate_encoded_size(record, max_bytes) do
    case Jason.encode(record) do
      {:ok, encoded} when byte_size(encoded) <= max_bytes -> :ok
      _ -> {:error, :record_too_large}
    end
  end

  defp parse_lifecycle(value) when is_binary(value) do
    Enum.find_value(@lifecycles, {:error, :invalid_lifecycle}, fn lifecycle ->
      if Atom.to_string(lifecycle) == value, do: {:ok, lifecycle}
    end)
  end

  defp parse_lifecycle(_value), do: {:error, :invalid_lifecycle}

  defp parse_source(value) when is_binary(value) do
    Enum.find_value(@sources, {:error, :invalid_source}, fn source ->
      if Atom.to_string(source) == value, do: {:ok, source}
    end)
  end

  defp parse_source(_value), do: {:error, :invalid_source}

  defp parse_observed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, observed_at, 0} -> {:ok, observed_at}
      _ -> {:error, :invalid_observed_at}
    end
  end

  defp parse_observed_at(_value), do: {:error, :invalid_observed_at}

  defp identity_from_record(
         %{
           "version" => 1,
           "status" => "joinable",
           "kind" => "github",
           "owner" => owner,
           "repository" => repository,
           "provider_id" => provider_id,
           "database_id" => database_id,
           "identifier" => identifier,
           "reason" => nil
         } = identity
       ) do
    if Enum.sort(Map.keys(identity)) == @identity_record_keys and valid_database_id(database_id) == :ok do
      tracker_identity = %TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: owner,
        repository: repository,
        provider_id: provider_id,
        database_id: database_id,
        identifier: identifier,
        reason: nil
      }

      if TrackerIdentity.joinable?(tracker_identity), do: {:ok, tracker_identity}, else: {:error, :invalid_identity}
    else
      {:error, :invalid_identity}
    end
  end

  defp identity_from_record(_identity), do: {:error, :invalid_identity}
end
