defmodule Aiur.Config.Schema.Rtk do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Controls whether the analytics panel reports host-level rtk output
    # savings. This does not enable or disable a host-wide rtk hook; the
    # operator owns that hook and must configure it to exclude `gh`.
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-reference config-configuration-agent-00 agent.rtk.enabled | boolean | false | Enables the Agent output compression panel on the analytics page, which reports rtk's host-level output savings when available. Aiur does not install, enable, or disable rtk's hook and does not enforce this setting at agent dispatch. A host-wide rtk hook applies to every agent regardless of this setting; the operator owns the hook and must exclude `gh` (`exclude_commands = ["gh"]` under `[hooks]`), because `gh` in an agent workspace is the GitHub quota guard and rtk must not rewrite it. The analytics panel reports rtk's status, including when its probe detects that `gh` would be rewritten, but cannot disable the hook. At daemon startup Aiur also checks the host hook, independent of this setting, and raises an informational alert when it would rewrite `gh`. |
    field(:enabled, :boolean, default: false)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    cast(schema, attrs, [:enabled], empty_values: [])
  end
end
