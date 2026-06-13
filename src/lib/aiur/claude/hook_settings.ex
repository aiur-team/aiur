defmodule Aiur.Claude.HookSettings do
  @moduledoc """
  Generate the `--settings` JSON that wires an RC-claude session's lifecycle hooks
  to POST to the aiur dashboard's claude-hook endpoint (see `Aiur.Claude.HookEvents`).

  `claude --settings <file>` ADDS a settings source — it composes with the user's
  own settings/hooks rather than replacing them, so our turn-detection hooks fire
  alongside whatever the operator already configured.
  """

  # UserPromptSubmit = input received; PostToolUse = progress/heartbeat; Stop = turn done.
  @events ["UserPromptSubmit", "PostToolUse", "Stop"]

  @doc "Settings map for an agent identifier + dashboard base URL."
  @spec settings(String.t(), String.t()) :: map()
  def settings(identifier, dashboard_url) when is_binary(identifier) and is_binary(dashboard_url) do
    command = hook_command(identifier, dashboard_url)
    entry = [%{"hooks" => [%{"type" => "command", "command" => command}]}]
    %{"hooks" => Map.new(@events, fn name -> {name, entry} end)}
  end

  @doc """
  The hook command claude runs for each event. It pipes the event JSON (stdin) to
  the dashboard. Three invariants make it safe to run inside a live claude session:

    * **stdout-silent** — claude injects a `UserPromptSubmit` hook's stdout as extra
      prompt context and lets a `Stop` hook's stdout block stopping, so the command
      must print nothing (`-o /dev/null` + redirect).
    * **fast** — `-m 2` so a stalled dashboard never delays the agent.
    * **always exit 0** — a non-zero hook can surface errors / alter behaviour.
  """
  @spec hook_command(String.t(), String.t()) :: String.t()
  def hook_command(identifier, dashboard_url) when is_binary(identifier) and is_binary(dashboard_url) do
    url = String.trim_trailing(dashboard_url, "/") <> "/api/v1/#{URI.encode(identifier)}/claude-hook"

    "curl -sS -m 2 -o /dev/null " <>
      "-H 'Content-Type: application/json' -H 'Origin: http://127.0.0.1' -H 'X-Aiur-Request: 1' " <>
      "--data-binary @- " <> single_quote(url) <> " >/dev/null 2>&1; exit 0"
  end

  @doc """
  Write the settings JSON to a temp file and return its path. The file persists for
  the claude session's lifetime (read once at startup via `--settings`).
  """
  @spec write(String.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def write(identifier, dashboard_url) when is_binary(identifier) and is_binary(dashboard_url) do
    dir = Path.join(System.tmp_dir!(), "aiur-claude-hooks")

    with :ok <- File.mkdir_p(dir),
         path = Path.join(dir, "#{slug(identifier)}-#{System.unique_integer([:positive])}.json"),
         :ok <- File.write(path, Jason.encode!(settings(identifier, dashboard_url))) do
      {:ok, path}
    end
  end

  @doc """
  Resolve the dashboard base URL aiur is serving on, or `nil` when the HTTP server
  has not bound a port yet. Mirrors `Aiur.PaneManager`'s control-url construction.
  """
  @spec dashboard_url() :: String.t() | nil
  def dashboard_url do
    case Aiur.HttpServer.bound_port() do
      port when is_integer(port) and port > 0 -> "http://#{host()}:#{port}"
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp host do
    case Aiur.Config.server_host() do
      h when h in ["0.0.0.0", "::", "", nil] -> "127.0.0.1"
      h when is_binary(h) -> h
    end
  end

  defp slug(identifier), do: String.replace(identifier, ~r/[^A-Za-z0-9_.-]/, "_")

  defp single_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
