defmodule Aiur.AgentRunner.Handoff do
  @moduledoc "Runner barrier and continuation for a daemon handoff."

  alias Aiur.AgentRunner.Handoff.ProviderState, as: AppHandoff
  alias Aiur.AgentRunner.{SessionLifecycle, TurnLoop}
  alias Aiur.AppServer.ProviderTurnLedger
  alias Aiur.AppServer.RelayPort
  alias Aiur.OpenAICompat.Handoff, as: SessionHandoff
  alias Aiur.Workspace.Ownership.Adoption
  alias Aiur.Workspace.WipPreservation

  @spec hold(pid()) :: :ok
  def hold(pid), do: send_hold(pid)

  defp send_hold(pid) do
    send(pid, :handoff_hold)
    :ok
  end

  @spec abort(pid()) :: :ok
  def abort(pid) do
    send(pid, :handoff_abort)
    :ok
  end

  @doc false
  @spec abort_all([pid()], timeout()) :: :ok
  def abort_all(pids, timeout \\ 5_000) do
    pending =
      Enum.map(pids, fn pid ->
        ref = make_ref()
        monitor = Process.monitor(pid)
        send(pid, {:handoff_abort, self(), ref})
        {pid, ref, monitor}
      end)

    deadline = System.monotonic_time(:millisecond) + timeout

    Enum.each(pending, fn {pid, ref, monitor} ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:handoff_aborted, ^ref} -> Process.demonitor(monitor, [:flush])
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        remaining -> Process.demonitor(monitor, [:flush])
      end
    end)

    :ok
  end

  @doc false
  @spec callback(function(), map()) :: function()
  def callback(fun, metadata) do
    Process.put({:handoff_callback, fun}, metadata)
    fun
  end

  @spec snapshot(pid(), timeout()) :: {:ok, map()} | {:error, term()}
  def snapshot(pid, timeout \\ 65_000) do
    ref = Process.monitor(pid)
    send(pid, {:handoff_snapshot, self(), ref})

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:runner_gone, reason}}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :snapshot_timeout}
    end
  end

  @doc false
  @spec before_turn(map(), map()) :: map()
  def before_turn(session, context) do
    Process.put(:handoff_turn_context, context)

    receive do
      :handoff_hold ->
        Process.put(:handoff_hold, true)

      :handoff_abort ->
        Process.delete(:handoff_hold)

      {:handoff_abort, from, ref} ->
        Process.delete(:handoff_hold)
        send(from, {:handoff_aborted, ref})
    after
      0 -> :ok
    end

    if Process.get(:handoff_hold) do
      receive do
        {:handoff_snapshot, from, ref} ->
          capture(session, nil, from, ref)

        :handoff_abort ->
          Process.delete(:handoff_hold)
          session

        {:handoff_abort, from, ref} ->
          Process.delete(:handoff_hold)
          send(from, {:handoff_aborted, ref})
          session
      end
    else
      session
    end
  end

  @doc false
  @spec active_resume?() :: boolean()
  def active_resume?, do: match?(%{"turn_state" => state} when is_binary(state), Process.get(:handoff_resume)) and not is_nil(decode(Process.get(:handoff_resume)["turn_state"]))

  @doc """
  Honor a daemon handoff hold at an in-turn safe checkpoint.

  Backends whose provider runs inside the daemon process cannot reach
  `before_turn/2` while a turn is in flight, so their run loop calls this at a
  step boundary. A successful handoff captures the record and parks until the
  daemon stops; an aborted preflight clears the hold and returns `:continue` so
  the turn resumes.
  """
  @spec mid_turn_checkpoint(map(), map() | nil) :: :continue
  def mid_turn_checkpoint(session, state) do
    receive do
      :handoff_hold ->
        Process.put(:handoff_hold, true)
        mid_turn_checkpoint(session, state)

      :handoff_abort ->
        Process.delete(:handoff_hold)
        :continue

      {:handoff_abort, from, ref} ->
        Process.delete(:handoff_hold)
        send(from, {:handoff_aborted, ref})
        :continue

      {:handoff_snapshot, from, ref} ->
        if Process.get(:handoff_hold), do: capture(session, state, from, ref)
        :continue
    after
      0 -> :continue
    end
  end

  @doc false
  @spec turn_prompt(map()) :: {String.t(), list()}
  def turn_prompt(context) do
    if active_resume?() do
      original = decode(Process.get(:handoff_resume)["turn_context"])
      {Map.get(original, :prompt, ""), []}
    else
      WipPreservation.with_pending_notices(
        context.workspace,
        context.issue.identifier,
        TurnLoop.build_turn_prompt(context.issue, context.workspace, Keyword.delete(context.opts, :pending_overrides), context.turn_number, context.max_turns)
      )
      |> then(fn {prompt, notices} -> {Aiur.Commands.render_pending_overrides(context.opts) <> prompt, notices} end)
    end
  end

  @doc "Park the runner for the new daemon; on abort return the live session so the caller resumes its own loop."
  @spec capture(map(), map() | nil, pid(), reference()) :: map()
  def capture(session, state, from, ref) do
    context = Process.get(:handoff_turn_context, %{})
    {transport, frames} = detach(session, state)
    fallback_reason = fallback_reason(transport, session, context)

    record = %{
      "backend" => Map.get(session, :backend, "unknown"),
      "fallback_reason" => fallback_reason,
      "workspace" => Map.get(session, :workspace) || context[:workspace],
      "session_state" => encode(session),
      "turn_state" => encode(turn_state(transport, state)),
      "turn_context" => encode(context),
      "queued_frames" => encode(frames),
      "display_state" => encode(display_state(session)),
      "transport" => transport
    }

    Process.put(:handoff_detached, is_nil(fallback_reason))
    send(from, {ref, {:ok, record}})
    park(record, session)
  end

  # An in-daemon backend's conversation lives in the run loop's own state, which
  # carries the resolved provider config — and its API key. Only the sanitized
  # conversation in the transport travels; the successor re-resolves credentials.
  defp turn_state(%{"kind" => "in_daemon"}, _state), do: nil
  defp turn_state(_transport, state), do: state

  defp fallback_reason(%{"kind" => kind}, session, context) when kind in ["direct", "unsupported"] do
    if session[:worker_host] || context[:worker_host], do: "remote_worker", else: "relay_protocol"
  end

  defp fallback_reason(%{"kind" => "in_daemon_failed"}, _session, _context), do: "session_unavailable"
  defp fallback_reason(_transport, _session, _context), do: nil

  defp display_state(session) do
    case Process.get(:handoff_display_tailer) do
      pid when is_pid(pid) -> Aiur.CodingAgent.display_tailer(session.backend).handoff_state(pid)
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp park(record, original_session) do
    receive do
      :handoff_abort ->
        resume_parked(record, original_session, nil)

      {:handoff_abort, from, ref} ->
        resume_parked(record, original_session, {from, ref})

      {:handoff_snapshot, from, ref} ->
        send(from, {ref, {:ok, record}})
        park(record, original_session)
    end
  end

  defp resume_parked(record, original_session, acknowledgment) do
    resumed = resumed_session(record, original_session)

    Process.put(:handoff_detached, false)
    Process.delete(:handoff_hold)

    case acknowledgment do
      {from, ref} -> send(from, {:handoff_aborted, ref})
      nil -> :ok
    end

    resumed
  end

  # A fallback, a REPL pane and an in-daemon session all keep the session the
  # aborted handoff never released; only a relay is re-attached.
  defp resumed_session(%{"fallback_reason" => reason}, original_session) when not is_nil(reason),
    do: original_session

  defp resumed_session(%{"transport" => %{"kind" => "repl"}} = record, original_session) do
    Enum.each(decode(record["queued_frames"]), &send(self(), {:claude_hook, original_session.identifier, &1}))
    original_session
  end

  defp resumed_session(%{"transport" => %{"kind" => "in_daemon"}}, original_session),
    do: original_session

  defp resumed_session(record, _original_session) do
    generation = record["transport"]["generation"] || 0

    case attach(record, generation + 1) do
      {:ok, session} -> session
      _ -> exit(:handoff_abort_restore_failed)
    end
  end

  defp detach(%{port: port} = _session, _state) when is_pid(port) do
    metadata = RelayPort.call(port, :detach)
    transport = metadata |> Map.new(fn {key, value} -> {to_string(key), value} end) |> Map.merge(%{"kind" => "relay", "protocol" => 1})
    {transport, drain_frames(port, [])}
  end

  defp detach(%{port: port}, _state) when is_port(port) do
    pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    {%{"kind" => "direct", "os_pid" => pid}, []}
  end

  defp detach(%{pane_id: pane} = session, _state) do
    cursor = Aiur.SessionHandle.hook_cursor(session.identifier)

    {%{
       "kind" => "repl",
       "pane_id" => pane,
       "socket" => Aiur.CodingAgent.adapter("claude-repl").handoff_socket_name(session),
       "hook_spool_offset" => cursor["offset"],
       "os_pid" => session[:os_pid],
       "process_group_id" => session[:process_group_id]
     }, drain_hooks(session.identifier, [])}
  end

  # An in-daemon provider (in-process HTTP) has no child process to re-attach to:
  # its adapter serializes the conversation instead. `state` is the run loop's
  # in-flight state when the handoff lands mid-turn, `nil` at a turn boundary.
  defp detach(%{backend: backend} = session, state) when is_binary(backend) do
    case in_daemon_transport(backend, session, state) do
      {:ok, transport} -> {transport, []}
      :unsupported -> {%{"kind" => "unsupported", "os_pid" => session[:os_pid]}, []}
    end
  end

  defp detach(session, _state), do: {%{"kind" => "unsupported", "os_pid" => session[:os_pid]}, []}

  defp in_daemon_transport(backend, session, state) do
    with adapter when is_atom(adapter) and not is_nil(adapter) <- adapter_for(backend),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :handoff_state, 2),
         {:ok, provider_state} <- adapter.handoff_state(session, state) do
      {:ok,
       %{
         "kind" => "in_daemon",
         "provider_state" => SessionHandoff.encode_provider_state(provider_state),
         "os_pid" => session[:os_pid]
       }}
    else
      _ -> in_daemon_failure(backend, session, state)
    end
  end

  # An unknown backend key must not raise here: the record then carries an
  # unsupported transport and the preflight reports it as a fallback.
  defp adapter_for(backend) do
    case Map.get(Aiur.CodingAgent.backends(), backend) do
      %{adapter: adapter} -> adapter
      _ -> nil
    end
  end

  defp in_daemon_failure(backend, session, _state) do
    if Aiur.CodingAgent.handoff_kind(backend) == :in_daemon,
      do: {:ok, %{"kind" => "in_daemon_failed", "os_pid" => session[:os_pid]}},
      else: :unsupported
  end

  defp drain_hooks(identifier, acc) do
    receive do
      {:claude_hook, ^identifier, event} -> drain_hooks(identifier, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_frames(port, acc) do
    receive do
      {^port, frame} -> drain_frames(port, [frame | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "Continue an existing turn without session startup or workspace provisioning."
  @spec adopt(map(), pos_integer(), pid() | nil, keyword()) :: term()
  def adopt(record, generation, recipient, opts \\ []) do
    context = decode(record["turn_context"])
    issue = context.issue
    workspace = context.workspace
    ownership_opts = Keyword.merge(opts, issue_id: issue.id, orchestrator: recipient, orchestrator_name: registered_name(recipient), worker_host: nil)
    # An in-daemon adapter needs the original session options to resolve
    # credentials and config for the restored session; they travel in the
    # record's turn context and the options given here win over that copy.
    session_opts = Keyword.merge(Enum.reject(context.opts || [], fn {_key, value} -> is_nil(value) end), opts)

    with {:ok, lease} <- Adoption.adopt(issue.identifier, workspace, ownership_opts),
         {:ok, session} <- attach(record, generation, session_opts) do
      :ok = Aiur.AgentRunner.maybe_attach_issue_log(issue)
      session = AppHandoff.restore_session(session, issue)
      opts = Keyword.put(session_opts, :workspace_ownership, lease)
      Process.put(:handoff_resume, record)
      opts = Keyword.put(opts, :run_turn, &resume_turn/4)

      display_state = if record["display_state"], do: decode(record["display_state"])
      {display_tailer, opts} = SessionLifecycle.start_adopted_display(session, issue, Keyword.put(opts, :handoff_display_state, display_state))
      notify_adoption(recipient, {:ok, session}, opts)

      try do
        SessionLifecycle.report_session_execution(recipient, issue, session)

        TurnLoop.run_turns(
          session,
          workspace,
          issue,
          recipient,
          opts,
          Keyword.get(opts, :issue_state_fetcher, &Aiur.Tracker.fetch_issue_states_by_ids/1),
          Keyword.get(opts, :orchestrator, Aiur.Orchestrator),
          nil,
          context.turn_number,
          context.max_turns
        )
      after
        SessionLifecycle.stop_display_tailer(display_tailer)
        SessionLifecycle.stop_session_with_ownership(session, lease)
      end
    else
      {:error, reason} = error ->
        notify_adoption(recipient, error, opts)
        {:error, reason}
    end
  end

  defp registered_name(pid) when is_pid(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> name
      _ -> nil
    end
  end

  defp registered_name(_), do: nil

  defp notify_adoption(recipient, result, opts) do
    if is_pid(recipient) and Keyword.get(opts, :adoption_notify?, true) do
      send(recipient, {:handoff_adopted, self(), result})

      if match?({:ok, _}, result) do
        receive do
          :handoff_continue -> :ok
        end
      end
    end
  end

  @doc false
  @spec attach(map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def attach(record, generation), do: attach(record, generation, [])

  @doc false
  @spec attach(map(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def attach(%{"transport" => %{"kind" => "relay"} = transport} = record, generation, _opts) do
    with {:ok, port} <- RelayPort.attach(transport["directory"], generation, transport["acked_offset"], actor_meta(record)) do
      session = decode(record["session_state"]) |> Map.put(:port, port)
      session = restore_provider_store(session, decode(record["turn_state"]))
      Process.put(:handoff_replay_frames, decode(record["queued_frames"]))
      {:ok, session}
    end
  end

  def attach(%{"transport" => %{"kind" => "repl", "socket" => socket}} = record, _generation, _opts) do
    session = decode(record["session_state"])

    with {:ok, session} <- Aiur.CodingAgent.adapter("claude-repl").restore_handoff_transport(session, socket, actor_meta(record)) do
      Enum.each(decode(record["queued_frames"]), &send(self(), {:claude_hook, session.identifier, &1}))
      {:ok, session}
    end
  end

  # An in-daemon session cannot be re-attached to: the successor daemon starts a
  # fresh provider session from the adapter's saved conversation.
  def attach(%{"transport" => %{"kind" => "in_daemon"}} = record, _generation, opts) do
    with adapter when is_atom(adapter) and not is_nil(adapter) <- adapter_for(record["backend"]),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :adopt_handoff_session, 2) do
      adapter.adopt_handoff_session(record, opts)
    else
      _ -> {:error, :unsupported_handoff_backend}
    end
  end

  # Fresh launches register their root with its ticket; an adopted root must too,
  # or run telemetry cannot attribute it and analytics reads an idle fleet (#4829).
  defp actor_meta(record) do
    case record["turn_context"] && decode(record["turn_context"]) do
      %{issue: %{identifier: ticket}} when is_binary(ticket) -> [ticket: ticket, backend: record["backend"], worker_host: nil, remote: false]
      _other -> []
    end
  end

  defp restore_provider_store(%{backend: "codex"} = session, state) do
    {:ok, store} = ProviderTurnLedger.start_store()
    if is_map(state), do: Agent.update(store, fn _ -> Map.take(state, [:retired_turn_ids, :anonymous_completion_consumed?]) end)
    Map.put(session, :provider_turn_store, store)
  end

  defp restore_provider_store(session, _state), do: session

  defp resume_turn(session, prompt, issue, opts) do
    case Process.delete(:handoff_resume) do
      nil ->
        Aiur.CodingAgent.run_turn(session, prompt, issue, opts)

      %{"transport" => %{"kind" => "in_daemon"}} = record ->
        resume_in_daemon_turn(session, record, prompt, issue, opts)

      %{"turn_state" => encoded} = record ->
        resume_active_turn(session, decode(encoded), record, prompt, issue, opts)
    end
  end

  # A mid-turn snapshot resumes that turn: the restored conversation already
  # holds its prompt and tool results, so re-running the cold-start prompt would
  # duplicate the brief. A turn-boundary snapshot starts the next turn normally.
  defp resume_in_daemon_turn(session, record, prompt, issue, opts) do
    if SessionHandoff.interrupted?(record),
      do: Aiur.CodingAgent.adapter(record["backend"]).resume_handoff_turn(session, opts),
      else: Aiur.CodingAgent.run_turn(session, prompt, issue, opts)
  end

  defp resume_active_turn(session, nil, _record, prompt, issue, opts), do: Aiur.CodingAgent.run_turn(session, prompt, issue, opts)

  defp resume_active_turn(%{backend: "claude-repl"} = session, state, record, _prompt, _issue, opts) do
    Aiur.CodingAgent.adapter("claude-repl").adopt_handoff_turn(session, state, record["transport"]["hook_spool_offset"], opts)
  end

  defp resume_active_turn(session, state, _record, _prompt, _issue, opts) do
    state = AppHandoff.restore(state, opts) |> Map.put(:provider_turn_store, Map.get(session, :provider_turn_store))

    case Aiur.AppServer.TurnLoop.receive_loop(session, state) do
      {:ok, result} -> {:ok, %{result: result, thread_id: session.thread_id, turn_id: state.current_turn_id, session_id: "#{session.thread_id}-#{state.current_turn_id}"}}
      other -> other
    end
  end

  @doc false
  @spec encode(term()) :: String.t()
  def encode(term), do: term |> portable() |> :erlang.term_to_binary() |> Base.encode64()

  @doc false
  @spec decode(String.t()) :: term()
  def decode(term) do
    binary = Base.decode64!(term)

    try do
      :erlang.binary_to_term(binary, [:safe])
    rescue
      # [:safe] refuses atoms not yet created; load modules only then, since loading them all can outlast the abort budget.
      ArgumentError ->
        load_snapshot_atoms()
        :erlang.binary_to_term(binary, [:safe])
    end
  end

  # Early boot has not loaded provider modules whose private state atoms the snapshot carries.
  defp load_snapshot_atoms do
    unless :persistent_term.get({__MODULE__, :snapshot_atoms_loaded}, false) do
      case Application.load(:aiur) do
        :ok -> :ok
        {:error, {:already_loaded, :aiur}} -> :ok
      end

      Enum.each(Application.spec(:aiur, :modules), &Code.ensure_loaded/1)
      :persistent_term.put({__MODULE__, :snapshot_atoms_loaded}, true)
    end
  end

  defp portable(term) when is_function(term), do: portable(Process.get({:handoff_callback, term}))
  defp portable(term) when is_pid(term) or is_port(term) or is_reference(term), do: nil
  defp portable(%module{} = term), do: struct(module, portable(Map.from_struct(term)))
  defp portable(term) when is_map(term), do: Map.new(term, fn {key, value} -> {portable(key), portable(value)} end)
  defp portable(term) when is_list(term), do: Enum.map(term, &portable/1)
  defp portable(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.map(&portable/1) |> List.to_tuple()
  defp portable(term), do: term
end
