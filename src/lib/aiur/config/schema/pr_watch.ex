defmodule Aiur.Config.Schema.PrWatch do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Opt-in. When false, aiur ignores comments on PRs it did not create
    # (no `agent:watch` polling, no per-comment command handling). Strict
    # opt-in keeps human-directed PR comments untouched.
    # @config-reference config-configuration-09 pr_watch.enabled
    # @config-detail pr_watch.enabled | boolean | false | Enables trusted PR comment watching. |
    field(:enabled, :boolean, default: false)
    # Label suffix that enrolls a PR for persistent comment watching; combined
    # with the github `label_prefix` (e.g. "agent" + "watch" -> "agent:watch").
    # @config-reference config-configuration-09 pr_watch.watch_label
    # @config-detail pr_watch.watch_label | string | `watch` | Label suffix enrolling a PR for watching. |
    field(:watch_label, :string, default: "watch")
    # One-off per-comment command prefix. A trusted comment beginning with this
    # (or mentioning the configured `daemon_account`) wakes an agent for that one
    # comment, no label required.
    # @config-reference config-configuration-09 pr_watch.command_prefix
    # @config-detail pr_watch.command_prefix | string | `/aiur` | One-off trusted comment command prefix. |
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
