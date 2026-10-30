defmodule Aiur.Executor.HookConfig do
  @moduledoc """
  Executor lifecycle hooks for explicit attach. `install/2` and `uninstall/1`
  edit only project-local Claude settings; `render/2` returns printable config.
  Install/uninstall require `repo_root:`. Install/render accept `extra_entries:`.
  Codex install returns `{:error, :print_only}`; its renderer includes trust guidance.
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

  @spec render(:claude | :codex, keyword()) :: String.t()
  def render(harness, opts \\ []) do
    json = Jason.encode!(%{"hooks" => entries(harness, Keyword.get(opts, :extra_entries, []))}, pretty: true)

    case harness do
      :claude -> json
      :codex -> "Merge into <repo>/.codex/hooks.json:\n#{json}\nReview and trust the hooks in Codex's /hooks review dialog.\n"
    end
  end

  @spec install(:claude | :codex, keyword()) :: :ok | {:error, term()}
  def install(harness, opts \\ [])
  def install(:codex, _opts), do: {:error, :print_only}

  def install(:claude, opts) do
    additions = entries(:claude, Keyword.get(opts, :extra_entries, []))
    command = get_in(additions, ["SessionStart", Access.at(0), "hooks", Access.at(0), "command"])
    HookSettingsFile.install(Keyword.fetch!(opts, :repo_root), additions, command)
  end

  @spec uninstall(keyword()) :: :ok | {:error, term()}
  def uninstall(opts), do: HookSettingsFile.uninstall(Keyword.fetch!(opts, :repo_root))

  defp entry(command, timeout), do: %{"hooks" => [%{"type" => "command", "command" => command, "timeout" => timeout}]}
  defp quote_sh(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
