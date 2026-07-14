defmodule Aiur.CurrentRunMembership.Event.Codec do
  @moduledoc false

  alias Aiur.TrackerIdentity

  @version 1
  @lifecycles [:queued, :retrying, :allocated, :running, :paused, :waiting, :replaced, :completed, :cancelled]
  @sources [:status_report, :tracker]
  @record_keys ~w(checksum identity lifecycle observed_at run_id source version)
  @identity_record_keys ~w(identifier kind owner provider_id reason repository status version)

  @spec validate_attributes(term(), term(), term(), term(), term()) :: :ok | {:error, atom()}
  def validate_attributes(run_id, identity, lifecycle, source, observed_at) do
    with :ok <- valid_run_id(run_id),
         :ok <- valid_identity(identity),
         :ok <- valid_lifecycle(lifecycle),
         :ok <- valid_source(source),
         :ok <- valid_observed_at(observed_at) do
      :ok
    end
  end

  @spec from_record(term()) ::
          {:ok, %{run_id: String.t(), identity: TrackerIdentity.t(), lifecycle: atom(), source: atom(), observed_at: DateTime.t(), checksum: String.t()}}
          | {:error, atom()}
  def from_record(record) when is_map(record) do
    with @record_keys <- record |> Map.keys() |> Enum.sort(),
         @version <- Map.get(record, "version"),
         {:ok, identity} <- identity_from_record(Map.get(record, "identity")),
         {:ok, lifecycle} <- parse_lifecycle(Map.get(record, "lifecycle")),
         {:ok, source} <- parse_source(Map.get(record, "source")),
         {:ok, observed_at} <- parse_observed_at(Map.get(record, "observed_at")),
         checksum when is_binary(checksum) <- Map.get(record, "checksum") do
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
      "identifier" => identity.identifier,
      "reason" => identity.reason
    }
  end

  defp valid_run_id(run_id) when is_binary(run_id) and byte_size(run_id) in 1..512 do
    if run_id == String.trim(run_id), do: :ok, else: {:error, :invalid_run_id}
  end

  defp valid_run_id(_run_id), do: {:error, :invalid_run_id}
  defp valid_identity(identity), do: if(TrackerIdentity.joinable?(identity), do: :ok, else: {:error, :unjoinable_identity})
  defp valid_lifecycle(lifecycle), do: if(lifecycle in @lifecycles, do: :ok, else: {:error, :invalid_lifecycle})
  defp valid_source(source), do: if(source in @sources, do: :ok, else: {:error, :invalid_source})
  defp valid_observed_at(%DateTime{utc_offset: 0, std_offset: 0}), do: :ok
  defp valid_observed_at(_observed_at), do: {:error, :invalid_observed_at}

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
           "identifier" => identifier,
           "reason" => nil
         } = identity
       ) do
    if Enum.sort(Map.keys(identity)) == @identity_record_keys do
      tracker_identity = %TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: owner,
        repository: repository,
        provider_id: provider_id,
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
