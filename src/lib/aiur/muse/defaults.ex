defmodule Aiur.Muse.Defaults do
  @moduledoc "Native Muse launch and approval defaults shared by onboarding and runtime."

  @spec command() :: String.t()
  def command, do: "muse serve"

  @spec approval_mode() :: String.t()
  def approval_mode, do: "onRequest"
end
