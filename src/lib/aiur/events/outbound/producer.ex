defmodule Aiur.Events.Outbound.Producer do
  @moduledoc false
  # aiur:event-bus-boundary-member

  require Logger

  alias Aiur.{Config, TrackerIdentity}
  alias Aiur.Events.Publisher

  @spec maybe_publish(String.t(), map(), TrackerIdentity.t(), String.t() | nil, DateTime.t() | nil) :: :ok
  def maybe_publish(topic, payload, identity, job_id, occurred_at) do
    if Config.events_export_enabled?(), do: publish(topic, payload, identity, job_id, occurred_at), else: :ok
  rescue
    error -> log_failure(topic, error)
  end

  @spec publish(String.t(), map(), TrackerIdentity.t(), String.t() | nil, DateTime.t() | nil, keyword()) :: :ok
  def publish(topic, payload, identity, job_id, occurred_at, opts \\ []) do
    publish_fun = Keyword.get(opts, :publish_fun, &Publisher.publish/3)

    _ =
      publish_fun.(topic, payload,
        issue_number: identity.identifier,
        identity: identity,
        observation_source: %{kind: :legacy, name: "outbound_source"},
        observation_provenance: %{run_id: job_id},
        occurred_at: occurred_at
      )

    :ok
  rescue
    error -> log_failure(topic, error)
  catch
    kind, reason -> log_failure(topic, {kind, reason})
  end

  defp log_failure(topic, _error) do
    Logger.warning("aiur_outbound_event phase=source_publish_failed topic=#{topic}")
    :ok
  end
end
