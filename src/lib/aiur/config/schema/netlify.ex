defmodule Aiur.Config.Schema.Netlify do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-24 netlify.enabled
    # @config-reference config-configuration-24 netlify.account_id
    # @config-reference config-configuration-24 netlify.poll_seconds
    # @config-reference config-configuration-24 netlify.credit_alert_threshold
    # @config-detail netlify.enabled | boolean | false | Enable the read-only Netlify usage poller and dashboard card. |
    # @config-detail netlify.account_id | string | nil | Netlify team/account ID to read. |
    # @config-detail netlify.poll_seconds | integer | 900 | Netlify usage polling interval in seconds. |
    # @config-detail netlify.credit_alert_threshold | integer | 0 | Emit a low-credit alert at or below this estimated balance; 0 disables the threshold. |
    field(:enabled, :boolean, default: false)
    field(:account_id, :string)
    field(:poll_seconds, :integer, default: 900)
    field(:credit_alert_threshold, :integer, default: 0)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :account_id, :poll_seconds, :credit_alert_threshold])
    |> validate_number(:poll_seconds, greater_than_or_equal_to: 60, less_than_or_equal_to: 86_400)
    |> validate_number(:credit_alert_threshold, greater_than_or_equal_to: 0)
  end
end
