defmodule Aiur.Init.Dotenv do
  @moduledoc """
  Loads `./.env` then `~/.aiur/.env` into the process environment for `aiur init`,
  matching the launcher's precedence. Existing environment values win, and any
  GitHub credential in `./.env` prevents GitHub credentials from the global file.
  """

  # existing env always wins / values never logged
  @spec load() :: :ok
  def load do
    if Aiur.Secrets.secrets_from_env?() do
      :ok
    else
      local = Path.join(File.cwd!(), ".env")
      global = Path.join([System.get_env("HOME") || System.user_home!(), ".aiur", ".env"])
      skip_global_github? = file_sets_github_credential?(local)
      load_file(local, false)
      load_file(global, skip_global_github?)
    end
  end

  defp file_sets_github_credential?(path) do
    case File.read(path) do
      {:ok, content} ->
        github_names = Aiur.Env.github_credential_names()
        Enum.any?(parse(content, include_empty: true), fn {key, value} -> key in github_names and value != "" end)

      {:error, _} ->
        false
    end
  end

  defp load_file(path, skip_github_credentials?) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> parse()
        |> Enum.reject(fn {key, _value} -> skip_github_credentials? and key in Aiur.Env.github_credential_names() end)
        |> Enum.each(&put_env_if_unset/1)

      {:error, _} ->
        :ok
    end
  end

  defp put_env_if_unset({key, value}) do
    if System.get_env(key) in [nil, ""], do: System.put_env(key, value)
    :ok
  end

  @spec parse(String.t(), keyword()) :: [{String.t(), String.t()}]
  defdelegate parse(content, opts \\ []), to: Aiur.Env.Dotenv
end
