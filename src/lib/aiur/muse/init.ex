defmodule Aiur.Muse.Init do
  @moduledoc "Muse-specific onboarding questions and native backend configuration."

  alias Aiur.Muse.Defaults
  @spec prompt(Aiur.Init.io()) :: map()
  def prompt(io) do
    %{trust_workspace: io.confirm.("Trust Muse to load skills and rules from agent workspaces?", false)}
  end

  @spec config(map()) :: map()
  def config(%{trust_workspace: trust_workspace}) do
    %{
      "command" => Defaults.command(),
      "trust_workspace" => trust_workspace,
      "approval_mode" => Defaults.approval_mode()
    }
  end
end
