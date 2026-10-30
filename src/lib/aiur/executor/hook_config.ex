defmodule Aiur.Executor.HookConfig do
  @moduledoc """
  Executor lifecycle hooks for explicit attach. `install/2` and `uninstall/1`
  edit only project-local Claude settings; `render/2` returns printable config.
  Extra entries are `%{event: name, command: command, timeout: seconds}`;
  commands owned by Aiur must begin with `AIUR_EXECUTOR_HOOK=1` for removal.
  """
  alias Aiur.Executor.{HookSettingsFile, HookToken}
  alias Aiur.Fs

  @marker "AIUR_EXECUTOR_HOOK=1"
  @common ~w(SessionStart UserPromptSubmit PostToolUse Stop SubagentStart SubagentStop SessionEnd)
  @claude @common ++ ~w(StopFailure Notification TaskCreated TaskCompleted)

  @spec url_path() :: Path.t()
  def url_path, do: String.replace_suffix(HookToken.path(), ".hook-token", ".hook-url")

  @doc "Publish the actual bound loopback URL, independent of the public dashboard URL."
  @spec write_url(pos_integer()) :: :ok | {:error, term()}
  def write_url(port) when is_integer(port) and port > 0 and port <= 65_535 do
    with :ok <- File.mkdir_p(Path.dirname(url_path())) do
      Fs.atomic_write(url_path(), "http://127.0.0.1:#{port}", mode: 0o600, fsync: true)
    end
  end

  @spec entries(:claude | :codex, list(map())) :: map()
  def entries(harness, extra \\ []) when harness in [:claude, :codex] do
    script =
      "u=$(cat " <>
        quote_sh(url_path()) <>
        " 2>/dev/null) || exit 0; " <>
        "curl -sS -m 2 -o /dev/null -H @" <>
        quote_sh(HookToken.headers_path()) <>
        " -H 'Content-Type: application/json' --data-binary @- " <>
        "\"$u/api/v1/executor/hook?harness=#{harness}\" >/dev/null 2>&1; exit 0"

    command = @marker <> " sh -c " <> quote_sh(script)
    events = if harness == :claude, do: @claude, else: @common
    initial = Map.new(events, &{&1, [entry(command, 3)]})

    Enum.reduce(extra, initial, fn %{event: event, command: command, timeout: timeout}, acc ->
      Map.update(acc, event, [entry(command, timeout)], &(&1 ++ [entry(command, timeout)]))
    end)
  end

  @spec render(:claude | :codex, list(map())) :: String.t()
  def render(harness, extra \\ []) do
    json = Jason.encode!(%{"hooks" => entries(harness, extra)}, pretty: true)

    case harness do
      :claude -> json
      :codex -> "Merge into <repo>/.codex/hooks.json:\n#{json}\nReview and trust the hooks in Codex's /hooks review dialog.\n"
    end
  end

  @spec install(Path.t(), list(map())) :: :ok | {:error, term()}
  def install(repo_root, extra \\ []) do
    additions = entries(:claude, extra)
    command = get_in(additions, ["SessionStart", Access.at(0), "hooks", Access.at(0), "command"])
    HookSettingsFile.install(repo_root, additions, command)
  end

  @spec uninstall(Path.t()) :: :ok | {:error, term()}
  def uninstall(repo_root), do: HookSettingsFile.uninstall(repo_root)

  defp entry(command, timeout), do: %{"hooks" => [%{"type" => "command", "command" => command, "timeout" => timeout}]}
  defp quote_sh(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
