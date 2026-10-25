defmodule Aiur.AgentEnvironment.ProviderAuth do
  @moduledoc false

  alias Aiur.{AgentScratch, Shell}

  @secret_names ~w(ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY)

  @spec stage(Path.t(), [{String.t(), String.t() | false}]) ::
          {:ok, [{String.t(), String.t() | false}], Path.t() | nil} | {:error, term()}
  def stage(workspace, env) when is_binary(workspace) and is_list(env) do
    secrets = Enum.filter(env, fn {name, value} -> name in @secret_names and is_binary(value) and value != "" end)
    safe_env = Enum.reject(env, fn {name, _value} -> name in @secret_names end)

    case secrets do
      [] ->
        {:ok, safe_env, nil}

      [{name, value}] when is_binary(value) and value != "" ->
        with :ok <- AgentScratch.install(workspace),
             directory = AgentScratch.dir(workspace),
             :ok <- File.chmod(directory, 0o700),
             {:ok, path} <- write_secret(directory, name, value) do
          {:ok, safe_env, path}
        end

      _ ->
        {:error, :invalid_provider_auth_environment}
    end
  end

  @spec shell_prefix(Path.t() | nil) :: String.t()
  def shell_prefix(nil), do: ""

  def shell_prefix(path) when is_binary(path) do
    escaped = Shell.escape(path)
    ". #{escaped}; auth_load_status=$?; rm -f #{escaped}; [ \"$auth_load_status\" -eq 0 ] && "
  end

  @spec cleanup(Path.t() | nil) :: :ok
  def cleanup(nil), do: :ok
  def cleanup(path) when is_binary(path), do: File.rm(path) |> ignore_missing()

  defp write_secret(directory, name, value) do
    path = Path.join(directory, "provider-auth-#{System.unique_integer([:positive])}.sh")
    content = "export #{name}=#{Shell.escape(value)}\n"

    with :ok <- File.write(path, content, [:binary, :exclusive]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    else
      {:error, reason} ->
        File.rm(path)
        {:error, {:provider_auth_file_unavailable, reason}}
    end
  end

  defp ignore_missing({:error, :enoent}), do: :ok
  defp ignore_missing(result), do: result
end
