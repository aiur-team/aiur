defmodule VoiceConverse.AgentFork.Codex do
  @moduledoc """
  Native Codex fork: `thread/fork` on an own `codex app-server` (stdio JSON-RPC), then one turn
  on the fork.

  The fork is `ephemeral` (kept in memory, no rollout file), `sandbox: "read-only"` and
  `approvalPolicy: "never"`; the turn passes a read-only `sandboxPolicy` too, because the
  documented fork params do not list `sandbox`. `lastTurnId` is never sent: the parent may be
  mid-turn, and an in-progress turn id is rejected, while an omitted one forks the whole history
  with an interruption marker and leaves the parent alone. The turn only ever targets the fork's
  thread id; a fork that comes back with the parent's id is refused.

  The server starts with hooks disabled and no `notify` program.

  The shared app-server daemon (needed for `experimentalPredictionMode`) and the
  `codex exec fork` CLI fallback are not used: neither is verified read-only yet.
  """

  @behaviour VoiceConverse.AgentFork

  alias VoiceConverse.AgentFork
  alias VoiceConverse.AgentFork.{Handle, OsProcess}

  # The user's hooks and `notify` program are arbitrary shell commands; none may run in the fork.
  @server_args ["app-server", "--disable", "hooks", "-c", "notify=[]"]

  @initialize_id 1
  @fork_id 2
  @turn_id 3

  @impl true
  def mode, do: :native

  @doc "The `thread/fork` params for a read-only copy of `thread_id`."
  @spec fork_params(String.t(), Path.t()) :: map()
  def fork_params(thread_id, cwd) do
    # The fork's history is not needed here, and the server requires `excludeTurns` for an
    # ephemeral fork of a paginated thread.
    %{threadId: thread_id, ephemeral: true, excludeTurns: true, sandbox: "read-only", approvalPolicy: "never", cwd: cwd}
  end

  @doc "The `turn/start` params for the question on the fork `fork_thread_id`."
  @spec turn_params(String.t(), String.t(), Path.t()) :: map()
  def turn_params(fork_thread_id, prompt, cwd) do
    %{
      threadId: fork_thread_id,
      input: [%{type: "text", text: prompt}],
      cwd: cwd,
      approvalPolicy: "never",
      sandboxPolicy: %{type: "readOnly", networkAccess: false}
    }
  end

  @impl true
  def preflight(%{session_id: id, cwd: cwd}, opts) when is_binary(cwd) do
    with true <- Handle.valid_session_id?(:codex, id) || {:error, :invalid_handle},
         {:ok, _exe} <- executable(opts),
         do: :ok
  end

  def preflight(_handle, _opts), do: {:error, :invalid_handle}

  @impl true
  def run(handle, question, ctx) do
    {:ok, exe} = executable(ctx.opts)
    started = System.monotonic_time(:millisecond)
    {port, os_pid} = OsProcess.open(exe, @server_args, env(handle, ctx.opts), handle.cwd)

    acc = %{
      port: port,
      handle: handle,
      prompt: AgentFork.native_prompt(question),
      started: started,
      fork_thread: nil,
      first_token_ms: nil,
      deltas: [],
      text: nil,
      tokens: nil
    }

    try do
      OsProcess.send_json(port, %{
        method: "initialize",
        id: @initialize_id,
        params: %{clientInfo: %{name: "voice_converse", title: "VoiceConverse", version: "0.1.0"}}
      })

      OsProcess.collect(port, ctx, acc, &handle_message/2)
    after
      OsProcess.stop(port, os_pid)
    end
  end

  defp handle_message(%{"id" => id, "error" => error}, _acc) when id in [@initialize_id, @fork_id, @turn_id] do
    {:halt, {:error, {:codex_rpc, id, error}}}
  end

  defp handle_message(%{"id" => @initialize_id, "result" => _}, acc) do
    OsProcess.send_json(acc.port, %{method: "initialized"})

    OsProcess.send_json(acc.port, %{
      method: "thread/fork",
      id: @fork_id,
      params: fork_params(acc.handle.session_id, acc.handle.cwd)
    })

    {:cont, acc}
  end

  defp handle_message(%{"id" => @fork_id, "result" => %{"thread" => %{"id" => fork_thread}}}, acc) do
    if fork_thread == acc.handle.session_id do
      {:halt, {:error, :fork_not_isolated}}
    else
      OsProcess.send_json(acc.port, %{
        method: "turn/start",
        id: @turn_id,
        params: turn_params(fork_thread, acc.prompt, acc.handle.cwd)
      })

      {:cont, %{acc | fork_thread: fork_thread}}
    end
  end

  # A request from the server (an approval, say) is refused: the fork never grants anything.
  defp handle_message(%{"id" => id, "method" => _}, acc) do
    OsProcess.send_json(acc.port, %{id: id, error: %{code: -32_000, message: "read-only fork: refused"}})
    {:cont, acc}
  end

  defp handle_message(%{"method" => method, "params" => %{"threadId" => thread} = params}, %{fork_thread: thread} = acc) do
    notification(method, params, acc)
  end

  defp handle_message(_message, acc), do: {:cont, acc}

  defp notification("item/agentMessage/delta", %{"delta" => delta}, acc) when is_binary(delta) do
    first = acc.first_token_ms || System.monotonic_time(:millisecond) - acc.started
    {:cont, %{acc | first_token_ms: first, deltas: [delta | acc.deltas]}}
  end

  defp notification("item/completed", %{"item" => %{"type" => "agentMessage", "text" => text}}, acc)
       when is_binary(text) do
    {:cont, %{acc | text: text}}
  end

  defp notification("thread/tokenUsage/updated", %{"tokenUsage" => tokens}, acc), do: {:cont, %{acc | tokens: tokens}}

  defp notification("turn/completed", %{"turn" => %{"status" => "completed"}}, acc) do
    usage = %{
      tokens: acc.tokens,
      first_token_ms: acc.first_token_ms,
      duration_ms: System.monotonic_time(:millisecond) - acc.started
    }

    {:halt, {:ok, acc.text || acc.deltas |> Enum.reverse() |> Enum.join(), usage}}
  end

  defp notification("turn/completed", %{"turn" => turn}, _acc), do: {:halt, {:error, {:turn, turn["status"]}}}
  defp notification(_method, _params, acc), do: {:cont, acc}

  defp env(%{config_dir: dir}, opts) when is_binary(dir), do: AgentFork.child_env(opts, [{"CODEX_HOME", dir}])
  defp env(_handle, opts), do: AgentFork.child_env(opts, [])

  defp executable(opts) do
    case System.find_executable(Keyword.get(opts, :codex_executable, "codex")) do
      nil -> {:error, :cli_not_found}
      exe -> {:ok, exe}
    end
  end
end
