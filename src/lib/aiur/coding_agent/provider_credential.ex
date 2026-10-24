defmodule Aiur.CodingAgent.ProviderCredential do
  @moduledoc false

  alias Aiur.CodingAgent.RouteCredentials

  @spec fingerprint(String.t(), map(), map()) :: String.t() | nil
  def fingerprint("claude", _settings, env) do
    fingerprint_value(env["CLAUDE_CODE_OAUTH_TOKEN"] || env["ANTHROPIC_API_KEY"])
  end

  def fingerprint("codex", _settings, env) do
    case env["CODEX_HOME"] do
      home when is_binary(home) ->
        case File.read(Path.join(home, "auth.json")) do
          {:ok, content} -> fingerprint_value(content)
          _ -> fingerprint_value(env["OPENAI_API_KEY"])
        end

      _ ->
        fingerprint_value(env["OPENAI_API_KEY"])
    end
  end

  def fingerprint(backend, settings, env) do
    agent = Map.get(settings, :agent, %{})
    configs = Map.get(agent, :backend_configs, %{}) || %{}
    config = Map.get(configs, backend, %{}) || %{}

    name = Map.get(config, "api_key_env") || RouteCredentials.missing_key_env(backend, api_key_fetcher: fn key -> env[key] end)
    fingerprint_value(if(is_binary(name), do: env[name], else: nil))
  end

  defp fingerprint_value(value) when is_binary(value) and value != "" do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  defp fingerprint_value(_value), do: nil
end
