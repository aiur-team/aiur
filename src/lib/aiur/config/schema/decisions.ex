defmodule Aiur.Config.Schema.Decisions do
  @moduledoc false

  @external_resource Path.relative_to(Path.join(__DIR__, "decisions_escalation.ex"), File.cwd!(), force: true)
  use Ecto.Schema

  import Ecto.Changeset

  alias Aiur.Config.Schema.Decisions.Escalation
  require Escalation

  @max_allowed_kinds 100
  @max_kind_length 100

  @primary_key false

  @type t :: %__MODULE__{
          escalation: Escalation.t(),
          require_suggested_responses: boolean(),
          supervisor_allowed_kinds: [String.t()],
          supervisor_allow_non_reversible: boolean()
        }

  embedded_schema do
    # @config-reference config-configuration-17 decisions.require_suggested_responses
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail decisions.require_suggested_responses | boolean | false | Require 2–3 options and the recommendation first for `decision.requested` Commands. Default accepts requests with an informational warning; enable only after reviewing warning counts. Native and attention Commands are exempt. |
    field(:require_suggested_responses, :boolean, default: false)
    embeds_one(:escalation, Aiur.Config.Schema.Decisions.Escalation, on_replace: :update, defaults_to_struct: true)
    # @config-reference config-configuration-17 decisions.supervisor_allowed_kinds
    # @config-detail decisions.supervisor_allowed_kinds | array | `[]` | Decision kinds an authenticated supervising Executor may answer. Empty means none. |
    field(:supervisor_allowed_kinds, {:array, :string}, default: [])
    # @config-reference config-configuration-17 decisions.supervisor_allow_non_reversible
    # @config-detail decisions.supervisor_allow_non_reversible | boolean | false | Allows supervisor policy to cover partially reversible or irreversible decisions. |
    field(:supervisor_allow_non_reversible, :boolean, default: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:supervisor_allowed_kinds, :supervisor_allow_non_reversible, :require_suggested_responses], empty_values: [])
    |> cast_embed(:escalation)
    |> validate_change(:supervisor_allowed_kinds, &validate_allowed_kinds/2)
    |> update_change(:supervisor_allowed_kinds, &normalize_allowed_kinds/1)
  end

  defp validate_allowed_kinds(field, kinds) when length(kinds) > @max_allowed_kinds do
    [{field, "must contain at most #{@max_allowed_kinds} kinds"}]
  end

  defp validate_allowed_kinds(field, kinds) do
    if Enum.all?(kinds, &valid_kind?/1) do
      []
    else
      [{field, "must contain non-empty kinds of at most #{@max_kind_length} characters without control characters"}]
    end
  end

  defp valid_kind?(kind) when is_binary(kind) do
    trimmed = String.trim(kind)
    trimmed != "" and String.length(trimmed) <= @max_kind_length and not unsafe_control_chars?(kind)
  end

  defp valid_kind?(_kind), do: false

  defp normalize_allowed_kinds(kinds) do
    kinds
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp unsafe_control_chars?(text) do
    text
    |> String.to_charlist()
    |> Enum.any?(&(&1 < 0x20 or &1 == 0x7F))
  end
end
