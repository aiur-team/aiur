defmodule Aiur.GitHub.Access.Wrapper do
  @moduledoc "Host wrapper location shared by the installer and governed command runner."

  @spec host_bin_dir() :: Path.t()
  def host_bin_dir do
    Application.get_env(:aiur, :host_guard_bin_dir) || Path.join(System.user_home!(), ".aiur/bin")
  end
end
