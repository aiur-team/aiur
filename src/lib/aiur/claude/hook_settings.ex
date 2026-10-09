defmodule Aiur.Claude.HookSettings do
  @moduledoc """
  Generate the `--settings` JSON that wires an RC-claude session's lifecycle hooks
  to POST to the aiur dashboard's claude-hook endpoint (see `Aiur.Claude.HookEvents`).

  `claude --settings <file>` ADDS a settings source — it composes with the user's
  own settings/hooks rather than replacing them, so our turn-detection hooks fire
  alongside whatever the Executor already configured.
  """

  alias Aiur.Config.Paths

  # UserPromptSubmit = input received; PostToolUse = progress/heartbeat;
  # Stop = turn done; StopFailure = terminal API failure.
  @events ["UserPromptSubmit", "PostToolUse", "Stop", "StopFailure"]

  @doc "Settings map for an agent identifier + dashboard base URL."
  @spec settings(String.t(), String.t()) :: map()
  def settings(identifier, dashboard_url)
      when is_binary(identifier) and is_binary(dashboard_url) do
    command = hook_command(identifier, dashboard_url)
    entry = [%{"hooks" => [%{"type" => "command", "command" => command}]}]
    %{"hooks" => Map.new(@events, fn name -> {name, entry} end)}
  end

  @doc """
  The hook command claude runs for each event. It durably spools the event JSON
  before piping it to the dashboard. Three invariants make it Claude-safe:

    * **stdout-silent** — claude injects a `UserPromptSubmit` hook's stdout as extra
      prompt context and lets a `Stop` hook's stdout block stopping, so the command
      must print nothing (`-o /dev/null` + redirect).
    * **fast** — `-m 2` so a stalled dashboard never delays the agent.
    * **always exit 0** — a non-zero hook can surface errors / alter behaviour.
  """
  @spec hook_command(String.t(), String.t()) :: String.t()
  def hook_command(identifier, dashboard_url)
      when is_binary(identifier) and is_binary(dashboard_url) do
    url =
      String.trim_trailing(dashboard_url, "/") <> "/api/v1/#{URI.encode(identifier)}/claude-hook"

    producer =
      case spool_path(identifier) do
        {:ok, path} ->
          helper = Application.app_dir(:aiur, "priv/claude_hook_spool.py")

          "aiur_hook_payload=$(python3 " <>
            single_quote(helper) <>
            " " <>
            single_quote(path) <>
            " 2>/dev/null) && printf '%s\\n' \"$aiur_hook_payload\" | "

        {:error, reason} ->
          raise ArgumentError, "cannot resolve durable Claude hook spool: #{inspect(reason)}"
      end

    producer <>
      "curl -sS -m 2 -o /dev/null " <>
      "-H 'Content-Type: application/json' -H 'Origin: http://127.0.0.1' -H 'X-Aiur-Request: 1' " <>
      "--data-binary @- " <> single_quote(url) <> " >/dev/null 2>&1; exit 0"
  end

  @doc "Durable per-agent hook spool, independent of the current daemon launch."
  @spec spool_path(String.t()) :: {:ok, Path.t()} | {:error, atom()}
  def spool_path(identifier) when is_binary(identifier) do
    with {:ok, root} <- Paths.runtime_state_dir() do
      {:ok, Path.join([root, "claude-hooks", slug(identifier) <> ".ndjson"])}
    end
  end

  @doc """
  Write the settings JSON to a temp file and return its path. The file persists for
  the claude session's lifetime (read once at startup via `--settings`).
  """
  @spec write(String.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def write(identifier, dashboard_url) when is_binary(identifier) and is_binary(dashboard_url) do
    dir = Path.join(System.tmp_dir!(), "aiur-claude-hooks")

    with :ok <- require_python(),
         {:ok, _spool} <- spool_path(identifier),
         :ok <- File.mkdir_p(dir),
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
    case Application.get_env(:aiur, :dashboard_url_fun) do
      dashboard_url_fun when is_function(dashboard_url_fun, 0) -> dashboard_url_fun.()
      _ -> nil
    end
  end

  defp slug(identifier), do: Paths.sanitize(identifier)

  defp require_python do
    if System.find_executable("python3"), do: :ok, else: {:error, :claude_hook_spool_requires_python3}
  end

  defp single_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
