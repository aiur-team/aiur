defmodule Aiur.Config.Schema.EventsExport do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Aiur.Config.WebhookDestination

  @primary_key false
  @type t :: %__MODULE__{}

  embedded_schema do
    # @config-reference config-configuration-11 events.export.enabled
    # @config-detail events.export.enabled | boolean | false | Enables the external event journal; a configured webhook URL also enables signed delivery. Restart to apply. |
    field(:enabled, :boolean, default: false)
    # @config-reference config-configuration-11 events.export.allow_private_destinations
    # @config-detail events.export.allow_private_destinations | boolean | false | Allows loopback, private, link-local, CGNAT and ULA webhook destinations. |
    field(:allow_private_destinations, :boolean, default: false)
    # @config-reference config-configuration-11 events.export.webhook_url
    # @config-detail events.export.webhook_url | string | nil | HTTPS endpoint receiving outbound event POSTs. |
    field(:webhook_url, :string)
    # @config-reference config-configuration-11 events.export.subject_id
    # @config-detail events.export.subject_id | string | nil | Delivers only events for this exact ticket or job identifier. |
    field(:subject_id, :string)
    # @config-reference config-configuration-11 events.export.max_pending_events
    # @config-detail events.export.max_pending_events | integer | 10000 | Maximum admitted events waiting for acknowledgement. |
    field(:max_pending_events, :integer, default: 10_000)
    # @config-reference config-configuration-11 events.export.retry_ms
    # @config-detail events.export.retry_ms | integer | 5000 | Initial delay for capped exponential delivery retries. |
    field(:retry_ms, :integer, default: 5_000)
    # @config-reference config-configuration-11 events.export.request_timeout_ms
    # @config-detail events.export.request_timeout_ms | integer | 15000 | Per-attempt webhook request timeout. |
    field(:request_timeout_ms, :integer, default: 15_000)
    # @config-reference config-configuration-11 events.export.retention_days
    # @config-detail events.export.retention_days | integer | 7 | Retention age in days (1..90); reserved until retention is installed. Not enforced by the writer. |
    field(:retention_days, :integer, default: 7)
    # @config-reference config-configuration-11 events.export.retention_max_events
    # @config-detail events.export.retention_max_events | integer | 50000 | Maximum retained records (1000..1000000); reserved until retention is installed. Not enforced by the writer. |
    field(:retention_max_events, :integer, default: 50_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :enabled,
        :allow_private_destinations,
        :webhook_url,
        :subject_id,
        :max_pending_events,
        :retry_ms,
        :request_timeout_ms,
        :retention_days,
        :retention_max_events
      ],
      empty_values: []
    )
    |> validate_required([:enabled, :retention_days, :retention_max_events])
    |> validate_number(:max_pending_events, greater_than: 0)
    |> validate_number(:retry_ms, greater_than: 0)
    |> validate_number(:request_timeout_ms, greater_than: 0)
    |> validate_number(:retention_days, greater_than_or_equal_to: 1, less_than_or_equal_to: 90)
    |> validate_number(:retention_max_events, greater_than_or_equal_to: 1_000, less_than_or_equal_to: 1_000_000)
    |> validate_webhook_url()
    |> validate_change(:subject_id, &validate_subject_id/2)
  end

  defp validate_webhook_url(changeset) do
    case get_field(changeset, :webhook_url) do
      nil ->
        changeset

      value ->
        case WebhookDestination.validate_url(value, get_field(changeset, :allow_private_destinations) == true) do
          :ok -> changeset
          {:error, message} -> add_error(changeset, :webhook_url, message)
        end
    end
  end

  defp validate_subject_id(:subject_id, value) when is_binary(value) do
    if String.match?(value, ~r/\A[A-Za-z0-9._:-]+\z/),
      do: [],
      else: [subject_id: "must be a non-empty opaque identifier"]
  end

  defp validate_subject_id(:subject_id, _value), do: [subject_id: "must be a non-empty opaque identifier"]
end
