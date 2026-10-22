defmodule VoiceConverse.AgentFork.ClaudeCode do
  @moduledoc """
  Native Claude Code fork: `claude -p --resume <id> --fork-session` in print mode.

  `--fork-session` gives the copy a new session id, so the parent's history is not touched;
  `--no-session-persistence` keeps the copy from writing a session file. Forking copies history,
  not the filesystem, and the copy runs in the parent's worktree, so write refusal is required:
  plan mode (passed explicitly, a fork does not restore it), read tools only, no MCP, and no one
  to approve a prompt. The read-only flags are recent, so the CLI's `--help` is probed once per
  executable; if one is missing the fork is refused with `{:error, :unsafe_cli}` rather than run
  with fewer limits.
  """

  @behaviour VoiceConverse.AgentFork

  alias VoiceConverse.AgentFork
  alias VoiceConverse.AgentFork.{Handle, OsProcess}

  # The flags that keep the fork read-only, hook-free and unpersisted. `--max-turns` is a cost
  # limit and is left out: the CLI accepts it but does not list it in `--help`.
  @required_flags ~w(--resume --fork-session --no-session-persistence --permission-mode --tools
                     --disallowedTools --strict-mcp-config --settings --permission-prompts --input-format
                     --output-format --include-partial-messages --verbose)

  # Hooks are arbitrary shell commands with write and network access; none may run in the fork.
  # (`--bare` also skips hooks, but it ignores the user's OAuth login.)
  @no_hooks ~s({"disableAllHooks":true})
  @probe_timeout_ms 5_000

  @impl true
  def mode, do: :native

  @doc "The exact argv of a fork of `session_id`."
  @spec argv(String.t(), pos_integer()) :: [String.t()]
  def argv(session_id, max_turns) do
    ["-p", "--resume", session_id, "--fork-session", "--no-session-persistence"] ++
      ["--permission-mode", "plan", "--tools", "Read,Grep,Glob", "--disallowedTools", "mcp__*"] ++
      [
        "--strict-mcp-config",
        "--settings",
        @no_hooks,
        "--permission-prompts",
        "none",
        "--max-turns",
        Integer.to_string(max_turns)
      ] ++
      ["--input-format", "stream-json", "--output-format", "stream-json", "--include-partial-messages", "--verbose"]
  end

  @impl true
  def preflight(%{session_id: id, cwd: cwd} = handle, opts) when is_binary(cwd) do
    with true <- Handle.valid_session_id?(:claude_code, id) || {:error, :invalid_handle},
         {:ok, exe} <- executable(opts) do
      probe(exe, env(handle, opts), cwd)
    end
  end

  def preflight(_handle, _opts), do: {:error, :invalid_handle}

  @impl true
  def run(handle, question, ctx) do
    {:ok, exe} = executable(ctx.opts)
    started = System.monotonic_time(:millisecond)
    argv = argv(handle.session_id, AgentFork.max_turns(ctx.opts))
    {port, os_pid} = OsProcess.open(exe, argv, env(handle, ctx.opts), handle.cwd)

    try do
      OsProcess.send_json(port, %{
        type: "user",
        message: %{role: "user", content: [%{type: "text", text: AgentFork.native_prompt(question)}]}
      })

      OsProcess.collect(port, ctx, %{started: started, first_token_ms: nil}, &handle_message/2)
    after
      # The stream-json process waits for more input after its answer; the group kill ends it.
      OsProcess.stop(port, os_pid)
    end
  end

  defp handle_message(%{"type" => "stream_event", "event" => event}, %{first_token_ms: nil} = acc) do
    case event do
      %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta"}} ->
        {:cont, %{acc | first_token_ms: System.monotonic_time(:millisecond) - acc.started}}

      _ ->
        {:cont, acc}
    end
  end

  defp handle_message(%{"type" => "result"} = result, acc) do
    usage = %{
      tokens: result["usage"],
      cost_usd: result["total_cost_usd"],
      first_token_ms: acc.first_token_ms,
      duration_ms: System.monotonic_time(:millisecond) - acc.started
    }

    case result do
      %{"subtype" => "success", "is_error" => false, "result" => text} when is_binary(text) ->
        {:halt, {:ok, text, usage}}

      _ ->
        {:halt, {:error, {:claude_result, result["subtype"]}}}
    end
  end

  defp handle_message(_message, acc), do: {:cont, acc}

  defp env(%{config_dir: dir}, opts) when is_binary(dir), do: AgentFork.child_env(opts, [{"CLAUDE_CONFIG_DIR", dir}])
  defp env(_handle, opts), do: AgentFork.child_env(opts, [])

  defp executable(opts) do
    case System.find_executable(Keyword.get(opts, :claude_executable, "claude")) do
      nil -> {:error, :cli_not_found}
      exe -> {:ok, exe}
    end
  end

  # Only a passing probe is cached: a failed one (a CLI mid-update, say) is retried next time.
  defp probe(exe, env, cwd) do
    key = {__MODULE__, :probe, exe}

    if :persistent_term.get(key, false) do
      :ok
    else
      with :ok <- probe_help(exe, env, cwd), do: :persistent_term.put(key, true)
    end
  end

  defp probe_help(exe, env, cwd) do
    case OsProcess.run(exe, ["--help"], env, cwd, @probe_timeout_ms) do
      {:ok, help, 0} -> if Enum.all?(@required_flags, &flag_listed?(help, &1)), do: :ok, else: {:error, :unsafe_cli}
      _ -> {:error, :unsafe_cli}
    end
  end

  defp flag_listed?(help, flag), do: Regex.match?(~r/(?<![\w-])#{Regex.escape(flag)}(?![\w-])/, help)
end
