defmodule Aiur.Config.Schema.Compaction.AutoTrigger do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-15 compaction.auto_trigger.enabled
    # @config-detail compaction.auto_trigger.enabled | boolean | false | Opt in to compaction when cumulative agent token usage reaches the configured threshold at human-review handoff. |
    field(:enabled, :boolean, default: false)
    # @config-reference config-configuration-15 compaction.auto_trigger.token_threshold
    # @config-detail compaction.auto_trigger.token_threshold | integer | 50000 | Minimum cumulative agent tokens required for threshold mode (must be at least 1000). |
    field(:token_threshold, :integer, default: 50_000)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :token_threshold], empty_values: [])
    |> validate_number(:token_threshold, greater_than_or_equal_to: 1_000)
  end
end

defmodule Aiur.Config.Schema.Compaction do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  alias Aiur.Config.Schema.Compaction.AutoTrigger

  @primary_key false
  embedded_schema do
    # @config-reference config-configuration-15 compaction.enabled
    # @config-detail compaction.enabled | boolean | false | Master switch for compaction; must be true to enable any compaction features. |
    field(:enabled, :boolean, default: false)
    # @config-reference config-configuration-15 compaction.backends
    # @config-detail compaction.backends | array | [] | Must contain only `codex`; every other provider is rejected by config validation. |
    field(:backends, {:array, :string}, default: [])
    # @config-reference config-configuration-15 compaction.manual_approval
    # @config-detail compaction.manual_approval | boolean | false | Explicit opt-in to compact on terminal handoff. |
    field(:manual_approval, :boolean, default: false)
    embeds_one(:auto_trigger, Aiur.Config.Schema.Compaction.AutoTrigger, on_replace: :update, defaults_to_struct: true)
    # @config-reference config-configuration-15 compaction.timeout_ms
    # @config-detail compaction.timeout_ms | integer | 30000 | Timeout in milliseconds for compaction API calls. |
    field(:timeout_ms, :integer, default: 30_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :backends, :manual_approval, :timeout_ms], empty_values: [])
    |> cast_embed(:auto_trigger, with: &AutoTrigger.changeset/2)
    |> validate_backends()
    |> validate_number(:timeout_ms, greater_than: 0)
  end

  defp validate_backends(changeset) do
    validate_change(changeset, :backends, fn _field, backends ->
      if Enum.any?(backends, &(&1 != "codex")) do
        [backends: "native compaction is supported only for 'codex'"]
      else
        []
      end
    end)
  end
end
