defmodule Aiur.AgentRunner.Handoff do
  @moduledoc "Runner barrier and continuation for a daemon handoff."

  alias Aiur.AgentRunner.Handoff.ProviderState, as: AppHandoff
  alias Aiur.AgentRunner.{SessionLifecycle, TurnLoop}
  alias Aiur.AppServer.ProviderTurnLedger
  alias Aiur.AppServer.RelayPort
  alias Aiur.Claude.DisplayTailer
  alias Aiur.Claude.Repl.Adoption, as: ReplAdoption
  alias Aiur.Claude.Repl.HookTurn
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
  @spec before_turn(map(), map()) :: :ok
  def before_turn(session, context) do
    Process.put(:handoff_turn_context, context)

    receive do
      :handoff_hold -> Process.put(:handoff_hold, true)
      :handoff_abort -> Process.delete(:handoff_hold)
    after
      0 -> :ok
    end

    if Process.get(:handoff_hold) do
      receive do
        {:handoff_snapshot, from, ref} -> capture(session, nil, from, ref)
        :handoff_abort -> Process.delete(:handoff_hold)
      end
    end

    :ok
  end

  @doc false
  @spec active_resume?() :: boolean()
  def active_resume?, do: match?(%{"turn_state" => state} when is_binary(state), Process.get(:handoff_resume)) and not is_nil(decode(Process.get(:handoff_resume)["turn_state"]))

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
        TurnLoop.build_turn_prompt(context.issue, context.workspace, context.opts, context.turn_number, context.max_turns)
      )
    end
  end

  @doc false
  @spec capture(map(), map() | nil, pid(), reference()) :: no_return()
  def capture(session, state, from, ref) do
    context = Process.get(:handoff_turn_context, %{})
    {transport, frames} = detach(session)
    fallback_reason = if transport["kind"] in ["direct", "unsupported"], do: if(session[:worker_host] || context[:worker_host], do: "remote_worker", else: "relay_protocol")

    record = %{
      "backend" => Map.get(session, :backend, "unknown"),
      "fallback_reason" => fallback_reason,
      "workspace" => Map.get(session, :workspace) || context[:workspace],
      "session_state" => encode(session),
      "turn_state" => encode(state),
      "turn_context" => encode(context),
      "queued_frames" => encode(frames),
      "display_state" => encode(display_state()),
      "transport" => transport
    }

    Process.put(:handoff_detached, is_nil(fallback_reason))
    send(from, {ref, {:ok, record}})
    park(record)
  end

  defp display_state do
    case Process.get(:handoff_display_tailer) do
      pid when is_pid(pid) -> DisplayTailer.handoff_state(pid)
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp park(record) do
    receive do
      :handoff_abort ->
        if record["fallback_reason"], do: exit(:normal)
        generation = record["transport"]["generation"] || 0

        case attach(record, generation + 1) do
          {:ok, session} -> Aiur.CodingAgent.stop_session(session)
          _ -> :ok
        end

        exit(:normal)

      {:handoff_snapshot, from, ref} ->
        send(from, {ref, {:ok, record}})
        park(record)
    end
  end

  defp detach(%{port: port}) when is_pid(port) do
    metadata = RelayPort.call(port, :detach)
    transport = metadata |> Map.new(fn {key, value} -> {to_string(key), value} end) |> Map.merge(%{"kind" => "relay", "protocol" => 1})
    {transport, drain_frames(port, [])}
  end

  defp detach(%{port: port}) when is_port(port) do
    pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    {%{"kind" => "direct", "os_pid" => pid}, []}
  end

  defp detach(%{pane_id: pane} = session) do
    cursor = Aiur.SessionHandle.hook_cursor(session.identifier)

    {%{
       "kind" => "repl",
       "pane_id" => pane,
       "socket" => ReplAdoption.socket_name(session),
       "hook_spool_offset" => cursor["offset"],
       "os_pid" => session[:os_pid],
       "process_group_id" => session[:process_group_id]
     }, drain_hooks(session.identifier, [])}
  end

  defp detach(session), do: {%{"kind" => "unsupported", "os_pid" => session[:os_pid]}, []}

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

    with {:ok, lease} <- Adoption.adopt(issue.identifier, workspace, ownership_opts),
         {:ok, session} <- attach(record, generation) do
      session = AppHandoff.restore_session(session, issue)
      opts = Keyword.merge(Enum.reject(context.opts || [], fn {_key, value} -> is_nil(value) end), opts)
      opts = Keyword.put(opts, :workspace_ownership, lease)
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
  def attach(%{"transport" => %{"kind" => "relay"} = transport} = record, generation) do
    with {:ok, port} <- RelayPort.attach(transport["directory"], generation, transport["acked_offset"]) do
      session = decode(record["session_state"]) |> Map.put(:port, port)
      session = restore_provider_store(session, decode(record["turn_state"]))
      Process.put(:handoff_replay_frames, decode(record["queued_frames"]))
      {:ok, session}
    end
  end

  def attach(%{"transport" => %{"kind" => "repl", "socket" => socket}} = record, _generation) do
    session = decode(record["session_state"])

    with {:ok, session} <- ReplAdoption.rebind(session, socket) do
      Enum.each(decode(record["queued_frames"]), &send(self(), {:claude_hook, session.identifier, &1}))
      {:ok, session}
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
      nil -> Aiur.CodingAgent.run_turn(session, prompt, issue, opts)
      %{"turn_state" => encoded} = record -> resume_active_turn(session, decode(encoded), record, prompt, issue, opts)
    end
  end

  defp resume_active_turn(session, nil, _record, prompt, issue, opts), do: Aiur.CodingAgent.run_turn(session, prompt, issue, opts)

  defp resume_active_turn(%{backend: "claude-repl"} = session, state, record, _prompt, _issue, opts) do
    HookTurn.adopt(session, state, record["transport"]["hook_spool_offset"], opts)
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
    load_snapshot_atoms()
    term |> Base.decode64!() |> :erlang.binary_to_term([:safe])
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
