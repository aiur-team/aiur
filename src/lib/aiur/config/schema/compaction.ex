defmodule Aiur.Config.Schema.Compaction.AutoTrigger do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field(:enabled, :boolean, default: false)
    field(:token_threshold, :integer, default: 50_000)
    field(:message_count_threshold, :integer, default: 20)
    field(:elapsed_time_minutes, :integer, default: 60)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    cast(schema, attrs, [:enabled, :token_threshold, :message_count_threshold, :elapsed_time_minutes], empty_values: [])
    |> validate_number(:token_threshold, greater_than_or_equal_to: 1000)
    |> validate_number(:message_count_threshold, greater_than_or_equal_to: 1)
    |> validate_number(:elapsed_time_minutes, greater_than_or_equal_to: 1)
  end
end

defmodule Aiur.Config.Schema.Compaction do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Aiur.Config.Schema.Compaction.AutoTrigger

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field(:enabled, :boolean, default: false)
    field(:backends, {:array, :string}, default: [])
    field(:manual_approval, :boolean, default: false)

    embeds_one(:auto_trigger, AutoTrigger, on_replace: :update, defaults_to_struct: true)
    field(:timeout_ms, :integer, default: 30_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :backends, :manual_approval, :timeout_ms], empty_values: [])
    |> cast_embed(:auto_trigger, with: &AutoTrigger.changeset/2)
    |> validate_backends()
    |> validate_thresholds()
  end

  defp validate_backends(changeset) do
    validate_change(changeset, :backends, fn _field, backends ->
      if Enum.any?(backends, &(&1 not in ["codex", "claude"])) do
        [backends: "contains unrecognized backend; only 'codex' and 'claude' are valid"]
      else
        []
      end
    end)
  end

  defp validate_thresholds(changeset) do
    auto_trigger = get_embed(changeset, :auto_trigger)
    if auto_trigger do
      token_threshold = get_change(auto_trigger, :token_threshold) || auto_trigger.changes[:token_threshold] || 50_000
      if is_integer(token_threshold) and token_threshold < 1000 do
        add_error(changeset, :auto_trigger, "token_threshold must be >= 1000")
      else
        changeset
      end
    else
      changeset
    end
  end
end
