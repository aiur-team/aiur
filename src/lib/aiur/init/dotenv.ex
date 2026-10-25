defmodule Aiur.Init.Dotenv do
  @moduledoc """
  Loads `.env` key=value pairs into the process environment for the `aiur init`
  wizard. `aiur init` runs as a bare foreground process (the launcher only
  sources .env for the running app, not init), so a GITHUB_TOKEN the Executor
  placed in the repo's .env is not yet in the environment.
  """

  @env_file_name ".env"

  # existing env always wins / values never logged
  @spec load() :: :ok
  def load do
    path = Path.join(File.cwd!(), @env_file_name)

    case File.read(path) do
      {:ok, content} -> Enum.each(parse(content), &put_env_if_unset/1)
      {:error, _} -> :ok
    end
  end

  defp put_env_if_unset({key, value}) do
    if System.get_env(key) in [nil, ""], do: System.put_env(key, value)
    :ok
  end

  @spec parse(String.t(), keyword()) :: [{String.t(), String.t()}]
  defdelegate parse(content, opts \\ []), to: Aiur.Env.Dotenv
end
