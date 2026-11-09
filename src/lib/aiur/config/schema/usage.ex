defmodule Aiur.Config.Schema.Usage do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Thresholds are keyed by provider because configured providers vary by workflow.
    # @config-reference config-configuration-23 usage.alerts
    # @config-detail usage.alerts | map | %{} | Per-provider low-usage alert thresholds; each threshold is remaining percent from 0 to 100. |
    field(:alerts, :map, default: %{})
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:alerts])
    |> validate_change(:alerts, &validate_alert_thresholds/2)
  end

  defp validate_alert_thresholds(:alerts, values) do
    Enum.flat_map(values, fn {provider, config} -> if valid_threshold?(config), do: [], else: [alerts: "#{provider} must set threshold between 0 and 100"] end)
  end

  defp valid_threshold?(%{threshold: threshold}), do: valid_threshold?(threshold)
  defp valid_threshold?(%{"threshold" => threshold}), do: valid_threshold?(threshold)
  defp valid_threshold?(threshold), do: is_number(threshold) and threshold >= 0 and threshold <= 100
end
