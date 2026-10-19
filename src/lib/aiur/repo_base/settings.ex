defmodule Aiur.RepoBase.Settings do
  @moduledoc false

  alias Aiur.Config
  alias Aiur.RepoBase
  alias Aiur.RepoBase.Clone

  @spec resolve() :: :disabled | {:ok, String.t(), Path.t(), String.t()}
  def resolve do
    with {:ok, settings} <- Config.settings(),
         %{enabled: true, base_build: command} when is_binary(command) and command != "" <- settings.prewarm,
         url when is_binary(url) and url != "" <- Clone.clone_url() do
      {:ok, url, RepoBase.base_path(url), command}
    else
      _ -> :disabled
    end
  end
end
