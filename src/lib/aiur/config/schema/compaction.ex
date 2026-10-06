defmodule Aiur.Config.Schema.Compaction.AutoTrigger do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:enabled, :boolean, default: false)
    field(:token_threshold, :integer, default: 50_000)
  end

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

  @primary_key false
  embedded_schema do
    field(:enabled, :boolean, default: false)
    field(:backends, {:array, :string}, default: [])
    field(:manual_approval, :boolean, default: false)
    embeds_one(:auto_trigger, Aiur.Config.Schema.Compaction.AutoTrigger, on_replace: :update, defaults_to_struct: true)

    field(:timeout_ms, :integer, default: 30_000)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :backends, :manual_approval, :timeout_ms], empty_values: [])
    |> cast_embed(:auto_trigger, with: &Aiur.Config.Schema.Compaction.AutoTrigger.changeset/2)
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
