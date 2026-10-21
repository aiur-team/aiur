defmodule Aiur.GitHub.Access.SettingsProvider do
  @moduledoc "The embedding application's live settings boundary for GitHub access."
  @callback settings() :: Aiur.GitHub.Access.Settings.t()
end
