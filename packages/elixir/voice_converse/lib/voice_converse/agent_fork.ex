defmodule VoiceConverse.AgentFork do
  @moduledoc """
  Answers a side question from a read-only copy of a live agent session, without stopping or
  changing the agent.

  `fork/3` picks one mode per harness:

    * `:native` for Claude Code (`claude -p --resume <id> --fork-session ...`) and Codex
      (`thread/fork` on an own `codex app-server`, ephemeral and read-only).
    * `:replay` for every other harness, OpenCode included until its read-only fork is checked:
      one call to the host's `:replay_model` with the briefing and the question.

  Read-only is the invariant of every mode: the fork never sends input to, resumes, or writes
  the parent session, its tools cannot write the parent's worktree, and the user's and the
  project's hooks do not run in it.

  The answer text is the agent's own words, unredacted: the caller redacts it before it reaches
  a voice provider.

  The answer arrives as a message to `:reply_to` (default the caller):

      {:fork_answer, ref, text, mode, usage}
      {:fork_failed, ref, reason}

  At most one fork runs per `:lock_key`; a second one gets `{:error, :fork_busy}`. When the
  timeout fires, or `:reply_to` exits, the fork's whole process group is killed.

  Options:

    * `:lock_key` - default `{harness, session_id}`; the voice session id is a good key.
    * `:env_drop` - extra variable names removed from the child env, such as every key the
      host loaded from `.env`. `GITHUB_TOKEN`, `GH_TOKEN` and the parent session ids are always
      removed (and the variables that tie a shell to its parent session). Without this an `ANTHROPIC_API_KEY` from `.env` would bill the API key instead
      of the user's own login.
    * `:max_turns` - default 6. `:timeout_ms` - default 60 000.
    * `:replay_model` - `(prompt -> {:ok, text} | {:ok, text, usage} | {:error, term})`.
      Without it replay is unavailable and `fork/3` returns `{:error, :none}`.
    * `:briefing` - text given to the replay model.
    * `:claude_executable`, `:codex_executable` - the CLI to run (default found on `PATH`).
  """

  alias VoiceConverse.AgentFork.{ClaudeCode, Codex, Handle, Replay}

  @type mode :: :native | :replay
  @type usage :: map()
  @type ctx :: %{deadline: integer(), watch: reference(), opts: keyword()}

  @doc "Checks the harness can fork now, before any process starts."
  @callback preflight(Handle.t(), keyword()) :: :ok | {:error, term()}
  @doc "Runs the fork to its answer within `ctx.deadline`."
  @callback run(Handle.t(), question :: String.t(), ctx()) :: {:ok, String.t(), usage()} | {:error, term()}
  @callback mode() :: mode()

  @default_timeout_ms 60_000
  @default_max_turns 6
  @always_dropped ["GITHUB_TOKEN", "GH_TOKEN"]

  @read_only_note """
  You are a read-only copy of this agent session, answering one side question from the user. \
  Do not edit or create files, do not run commands that change anything, and do not continue \
  the task. Answer briefly from what you already know and what read-only tools show.\
  """

  @doc "The fork capability for `handle`: `:native`, `:replay`, or `:none` when replay has no model."
  @spec capability(Handle.t(), keyword()) :: :native | :replay | :none
  def capability(handle, opts \\ []) do
    case harness(handle) do
      Replay -> if Replay.preflight(handle, opts) == :ok, do: :replay, else: :none
      module -> module.mode()
    end
  end

  @doc "Starts a fork answering `question`. See the moduledoc for the reply messages."
  @spec fork(Handle.t(), String.t(), keyword()) ::
          {:ok, reference()} | {:error, :fork_busy | :none | :unsafe_cli | term()}
  def fork(%{harness: _} = handle, question, opts \\ []) when is_binary(question) do
    module = harness(handle)

    with :ok <- module.preflight(handle, opts) do
      start_worker(module, handle, question, opts)
    end
  end

  @doc "The read-only instruction every fork gets with its question."
  @spec read_only_note() :: String.t()
  def read_only_note, do: @read_only_note

  @doc false
  @spec native_prompt(String.t()) :: String.t()
  def native_prompt(question), do: @read_only_note <> "\n\nQuestion: " <> question

  @doc false
  @spec child_env(keyword(), [{String.t(), String.t()}]) :: [{charlist(), charlist() | false}]
  def child_env(opts, set) do
    dropped = Enum.uniq(@always_dropped ++ Handle.parent_env_names() ++ Keyword.get(opts, :env_drop, []))
    set_names = Enum.map(set, &elem(&1, 0))

    Enum.map(dropped -- set_names, &{String.to_charlist(&1), false}) ++
      Enum.map(set, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
  end

  @doc false
  @spec max_turns(keyword()) :: pos_integer()
  def max_turns(opts), do: Keyword.get(opts, :max_turns, @default_max_turns)

  defp harness(%{harness: :claude_code}), do: ClaudeCode
  defp harness(%{harness: :codex}), do: Codex
  defp harness(_handle), do: Replay

  defp start_worker(module, handle, question, opts) do
    caller = self()
    reply_to = Keyword.get(opts, :reply_to, caller)
    ref = make_ref()
    lock = {{__MODULE__, Keyword.get(opts, :lock_key, {handle.harness, handle.session_id})}, ref}

    {_pid, monitor} =
      spawn_monitor(fn -> worker(module, handle, question, opts, caller, reply_to, ref, lock) end)

    receive do
      {^ref, :started} ->
        Process.demonitor(monitor, [:flush])
        {:ok, ref}

      {^ref, :busy} ->
        Process.demonitor(monitor, [:flush])
        {:error, :fork_busy}

      {:DOWN, ^monitor, :process, _, reason} ->
        {:error, {:fork_crashed, reason}}
    end
  end

  # The lock belongs to this process, so it is released if the worker dies for any reason.
  defp worker(module, handle, question, opts, caller, reply_to, ref, lock) do
    if :global.set_lock(lock, [node()], 0) do
      watch = Process.monitor(reply_to)
      send(caller, {ref, :started})
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      ctx = %{deadline: System.monotonic_time(:millisecond) + timeout_ms, watch: watch, opts: opts}
      result = safe_run(module, handle, question, ctx)
      # Free the key before answering, so the caller can fork again as soon as it hears back.
      :global.del_lock(lock, [node()])
      reply(reply_to, ref, module.mode(), result)
    else
      send(caller, {ref, :busy})
    end
  end

  defp safe_run(module, handle, question, ctx) do
    module.run(handle, question, ctx)
  rescue
    error -> {:error, {:crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:crashed, {kind, reason}}}
  end

  defp reply(_reply_to, _ref, _mode, {:error, :caller_down}), do: :ok
  defp reply(reply_to, ref, mode, {:ok, text, usage}), do: send(reply_to, {:fork_answer, ref, text, mode, usage})
  defp reply(reply_to, ref, _mode, {:error, reason}), do: send(reply_to, {:fork_failed, ref, reason})
end
