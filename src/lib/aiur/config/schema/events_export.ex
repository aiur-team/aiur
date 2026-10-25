defmodule Aiur.Config.Schema.EventsExport do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @type t :: %__MODULE__{}

  embedded_schema do
    # @config-reference config-configuration-11 events.export.enabled
    # @config-detail events.export.enabled | boolean | false | Enables signed outbound webhook delivery. |
    field(:enabled, :boolean, default: false)
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
    # @config-detail events.export.retry_ms | integer | 5000 | Delay before retrying a failed delivery. |
    field(:retry_ms, :integer, default: 5_000)
    # @config-reference config-configuration-11 events.export.request_timeout_ms
    # @config-detail events.export.request_timeout_ms | integer | 15000 | Per-attempt webhook request timeout. |
    field(:request_timeout_ms, :integer, default: 15_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :webhook_url, :subject_id, :max_pending_events, :retry_ms, :request_timeout_ms], empty_values: [])
    |> validate_number(:max_pending_events, greater_than: 0)
    |> validate_number(:retry_ms, greater_than: 0)
    |> validate_number(:request_timeout_ms, greater_than: 0)
    |> validate_change(:webhook_url, &validate_webhook_url/2)
    |> validate_change(:subject_id, &validate_subject_id/2)
    |> require_url_when_enabled()
  end

  defp require_url_when_enabled(changeset) do
    if get_field(changeset, :enabled), do: validate_required(changeset, [:webhook_url]), else: changeset
  end

  defp validate_webhook_url(:webhook_url, value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}} when is_binary(host) and host != "" ->
        []

      _other ->
        [webhook_url: "must be an HTTPS URL with a host and without userinfo or a fragment"]
    end
  end

  defp validate_webhook_url(:webhook_url, _value), do: [webhook_url: "must be an HTTPS URL"]

  defp validate_subject_id(:subject_id, value) when is_binary(value) do
    if String.match?(value, ~r/\A[A-Za-z0-9._:-]+\z/),
      do: [],
      else: [subject_id: "must be a non-empty opaque identifier"]
  end

  defp validate_subject_id(:subject_id, _value), do: [subject_id: "must be a non-empty opaque identifier"]
end
