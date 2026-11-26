defmodule Aiur.GitHub.Access.StaticSettings do
  @moduledoc "Standalone provider: put a Settings struct in :aiur, :github_access_settings."
  @behaviour Aiur.GitHub.Access.SettingsProvider

  @impl true
  def settings do
    %Aiur.GitHub.Access.Settings{} = Application.fetch_env!(:aiur, :github_access_settings)
  end
end
