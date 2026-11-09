defmodule Aiur.Config.Schema.Decisions.Escalation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @default_ack_ms 300_000
  @default_answer_ms 900_000
  @default_urgent_factor 0.5
  @primary_key false
  @type t :: %__MODULE__{}

  embedded_schema do
    # @config-reference config-configuration-17 decisions.escalation.enabled
    # @config-detail decisions.escalation.enabled | boolean | true | Enables escalation of Executor Commands to the operator. |
    field(:enabled, :boolean, default: true)
    # @config-reference config-configuration-17 decisions.escalation.executor_ack_ms
    # @config-detail decisions.escalation.executor_ack_ms | integer | 300000 | Acknowledgement deadline in milliseconds; minimum 10000. |
    field(:executor_ack_ms, :integer, default: @default_ack_ms)
    # @config-reference config-configuration-17 decisions.escalation.executor_answer_ms
    # @config-detail decisions.escalation.executor_answer_ms | integer | 900000 | Answer deadline in milliseconds; must be at least executor_ack_ms. |
    field(:executor_answer_ms, :integer, default: @default_answer_ms)
    # @config-reference config-configuration-17 decisions.escalation.urgent_factor
    # @config-detail decisions.escalation.urgent_factor | float | 0.5 | Multiplies both deadlines for urgent Commands; greater than 0 and at most 1. |
    field(:urgent_factor, :float, default: @default_urgent_factor)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :executor_ack_ms, :executor_answer_ms, :urgent_factor], empty_values: [])
    |> validate_required([:enabled, :executor_ack_ms, :executor_answer_ms, :urgent_factor])
    |> validate_number(:executor_ack_ms, greater_than_or_equal_to: 10_000)
    |> validate_number(:urgent_factor, greater_than: 0, less_than_or_equal_to: 1)
    |> validate_deadline_order()
  end

  defp validate_deadline_order(changeset) do
    ack_ms = get_field(changeset, :executor_ack_ms)
    answer_ms = get_field(changeset, :executor_answer_ms)

    if is_integer(ack_ms) and is_integer(answer_ms) and answer_ms < ack_ms do
      add_error(changeset, :executor_answer_ms, "must be at least executor_ack_ms")
    else
      changeset
    end
  end
end
