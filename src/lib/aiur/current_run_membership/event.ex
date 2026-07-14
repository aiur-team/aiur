defmodule Aiur.CurrentRunMembership.Event do
  @moduledoc false

  alias Aiur.CurrentRunMembership.Event.Codec
  alias Aiur.TrackerIdentity

  @version 1
  @terminal_lifecycles [:completed, :cancelled]

  @enforce_keys [:run_id, :identity, :lifecycle, :source, :observed_at, :checksum]
  defstruct version: @version,
            run_id: nil,
            identity: nil,
            lifecycle: nil,
            source: :status_report,
            observed_at: nil,
            checksum: nil

  @type lifecycle :: :queued | :retrying | :allocated | :running | :paused | :waiting | :replaced | :completed | :cancelled
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

  @spec new(String.t(), TrackerIdentity.t(), lifecycle(), DateTime.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def new(run_id, identity, lifecycle, observed_at, opts \\ []) do
    source = Keyword.get(opts, :source, :status_report)

    with :ok <- Codec.validate_attributes(run_id, identity, lifecycle, source, observed_at) do
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
      "identity" => Codec.identity_record(event.identity),
      "lifecycle" => Atom.to_string(event.lifecycle),
      "source" => Atom.to_string(event.source),
      "observed_at" => DateTime.to_iso8601(event.observed_at),
      "checksum" => event.checksum
    }
  end

  @spec from_record(term()) :: {:ok, t()} | {:error, atom()}
  def from_record(record) do
    with {:ok, attrs} <- Codec.from_record(record),
         {:ok, event} <- new(attrs.run_id, attrs.identity, attrs.lifecycle, attrs.observed_at, source: attrs.source),
         true <- event.checksum == attrs.checksum do
      {:ok, event}
    else
      false -> {:error, :invalid_checksum}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = event) do
    case new(event.run_id, event.identity, event.lifecycle, event.observed_at, source: event.source) do
      {:ok, rebuilt} -> rebuilt.checksum == event.checksum
      _ -> false
    end
  end

  def valid?(_event), do: false

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
