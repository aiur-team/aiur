defmodule Aiur.CurrentRunMembership.Event do
  @moduledoc false

  alias Aiur.TrackerIdentity

  @version 1
  @lifecycles [:queued, :retrying, :allocated, :running, :paused, :waiting, :replaced, :completed, :cancelled]
  @terminal_lifecycles [:completed, :cancelled]
  @sources [:status_report, :tracker]
  @record_keys ~w(checksum identity lifecycle observed_at run_id source version)
  @identity_record_keys ~w(identifier kind owner provider_id reason repository status version)

  @enforce_keys [:run_id, :identity, :lifecycle, :source, :observed_at, :checksum]
  defstruct version: @version,
            run_id: nil,
            identity: nil,
            lifecycle: nil,
            source: :status_report,
            observed_at: nil,
            checksum: nil

  @type lifecycle :: unquote(Enum.reduce(@lifecycles, fn lifecycle, acc -> {:|, [], [lifecycle, acc]} end))
  @type source :: :status_report | :tracker

  @type t :: %__MODULE__{
          version: pos_integer(),
          run_id: String.t(),
          identity: TrackerIdentity.t(),
          lifecycle: lifecycle(),
          source: source(),
          observed_at: DateTime.t(),
          checksum: String.t()
        }

  @spec new(String.t(), TrackerIdentity.t(), lifecycle(), DateTime.t(), keyword()) ::
          {:ok, t()} | {:error, atom()}
  def new(run_id, identity, lifecycle, observed_at, opts \\ []) do
    source = Keyword.get(opts, :source, :status_report)

    with :ok <- valid_run_id(run_id),
         :ok <- valid_identity(identity),
         :ok <- valid_lifecycle(lifecycle),
         :ok <- valid_source(source),
         :ok <- valid_observed_at(observed_at) do
      event = %__MODULE__{
        run_id: run_id,
        identity: identity,
        lifecycle: lifecycle,
        source: source,
        observed_at: observed_at,
        checksum: nil
      }

      {:ok, %{event | checksum: checksum(event)}}
    end
  end

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{lifecycle: lifecycle}), do: lifecycle in @terminal_lifecycles

  @spec to_record(t()) :: map()
  def to_record(%__MODULE__{} = event) do
    %{
      "version" => event.version,
      "run_id" => event.run_id,
      "identity" => identity_record(event.identity),
      "lifecycle" => Atom.to_string(event.lifecycle),
      "source" => Atom.to_string(event.source),
      "observed_at" => DateTime.to_iso8601(event.observed_at),
      "checksum" => event.checksum
    }
  end

  @spec from_record(term()) :: {:ok, t()} | {:error, atom()}
  def from_record(record) when is_map(record) do
    with @record_keys <- record |> Map.keys() |> Enum.sort(),
         @version <- Map.get(record, "version"),
         {:ok, identity} <- identity_from_record(Map.get(record, "identity")),
         {:ok, lifecycle} <- parse_lifecycle(Map.get(record, "lifecycle")),
         {:ok, source} <- parse_source(Map.get(record, "source")),
         {:ok, observed_at} <- parse_observed_at(Map.get(record, "observed_at")),
         checksum when is_binary(checksum) <- Map.get(record, "checksum"),
         {:ok, event} <- new(Map.get(record, "run_id"), identity, lifecycle, observed_at, source: source),
         true <- event.checksum == checksum do
      {:ok, event}
    else
      false -> {:error, :invalid_checksum}
      _ -> {:error, :invalid_record}
    end
  end

  def from_record(_record), do: {:error, :invalid_record}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = event) do
    case new(event.run_id, event.identity, event.lifecycle, event.observed_at, source: event.source) do
      {:ok, rebuilt} -> rebuilt.checksum == event.checksum
      _ -> false
    end
  end

  def valid?(_event), do: false

  defp valid_run_id(run_id) when is_binary(run_id) and byte_size(run_id) in 1..512 do
    if run_id == String.trim(run_id), do: :ok, else: {:error, :invalid_run_id}
  end

  defp valid_run_id(_run_id), do: {:error, :invalid_run_id}

  defp valid_identity(identity) do
    if TrackerIdentity.joinable?(identity), do: :ok, else: {:error, :unjoinable_identity}
  end

  defp valid_lifecycle(lifecycle) do
    if lifecycle in @lifecycles, do: :ok, else: {:error, :invalid_lifecycle}
  end

  defp valid_source(source) do
    if valid_source?(source), do: :ok, else: {:error, :invalid_source}
  end

  defp valid_observed_at(%DateTime{utc_offset: 0, std_offset: 0}), do: :ok
  defp valid_observed_at(_observed_at), do: {:error, :invalid_observed_at}

  defp valid_source?(source), do: source in @sources

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

      if TrackerIdentity.joinable?(tracker_identity) do
        {:ok, tracker_identity}
      else
        {:error, :invalid_identity}
      end
    else
      {:error, :invalid_identity}
    end
  end

  defp identity_from_record(_identity), do: {:error, :invalid_identity}

  defp identity_record(%TrackerIdentity{} = identity) do
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

  defp checksum(event) do
    event
    |> to_checksum_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp to_checksum_term(event) do
    {
      event.version,
      event.run_id,
      event.identity.version,
      event.identity.status,
      event.identity.kind,
      event.identity.owner,
      event.identity.repository,
      event.identity.provider_id,
      event.identity.identifier,
      event.identity.reason,
      event.lifecycle,
      event.source,
      DateTime.to_iso8601(event.observed_at)
    }
  end
end
