defmodule Aiur.Config.Schema.PrWatch do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Opt-in. When false, aiur ignores comments on PRs it did not create
    # (no `agent:watch` polling, no per-comment command handling). Strict
    # opt-in keeps human-directed PR comments untouched.
    field(:enabled, :boolean, default: false)
    # Label suffix that enrolls a PR for persistent comment watching; combined
    # with the github `label_prefix` (e.g. "agent" + "watch" -> "agent:watch").
    field(:watch_label, :string, default: "watch")
    # One-off per-comment command prefix. A trusted comment beginning with this
    # (or mentioning the configured `bot_account`) wakes an agent for that one
    # comment, no label required.
    field(:command_prefix, :string, default: "/aiur")
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :watch_label, :command_prefix], empty_values: [])
    |> validate_length(:watch_label, min: 1)
    |> validate_length(:command_prefix, min: 1)
  end
end
