defmodule Aiur.Handoff.Adopter do
  @moduledoc "Adopts handed-off runtimes before startup cleanup and the first poll."
  require Logger

  alias Aiur.AgentRunner.Handoff, as: Runner
  alias Aiur.AppServer.RelayPort
  alias Aiur.Config.Paths
  alias Aiur.Handoff.{Compatibility, Record, Report}
  alias Aiur.Handoff.Fallback
  alias Aiur.Orchestrator.{AdoptedBoot, DispatchPolicy, Slots, State}
  alias Aiur.Tracker

  @spec adopt(State.t(), keyword()) :: State.t()
  def adopt(state, opts \\ []) do
    case Record.read_raw(opts) do
      {:ok, record} ->
        consume(state, record, opts)

      :none ->
        state

      {:error, reason} ->
        alert(reason, opts)
        state
    end
  end

  defp consume(state, record, opts) do
    validation = Record.validate(record, opts)
    opts = Keyword.put_new_lazy(opts, :generation, fn -> generation(opts) end)

    agents =
      case record["agents"] do
        agents when is_list(agents) -> Enum.filter(agents, &is_map/1)
        _ -> []
      end

    {next, outcomes} = Enum.reduce(agents, {state, []}, &adopt_one(&1, &2, record, validation, opts))
    if match?({:error, _}, validation), do: alert(elem(validation, 1), opts)
    finish_consumption(state, next, agents, record, outcomes, opts)
  end

  defp finish_consumption(previous, next, agents, record, outcomes, opts) do
    case Record.consume(Enum.reverse(outcomes), opts) do
      :ok ->
        failed_ids = outcomes |> Enum.filter(&(Map.get(&1, :status) == "fallback")) |> Enum.map(& &1.issue_id)
        next = fallback_agents(next, Enum.filter(agents, &(&1["issue_id"] in failed_ids)), opts)
        next = AdoptedBoot.restore(next)
        for {_id, entry} <- next.running, entry[:adopted_from] == record["handoff_id"], do: send(entry.pid, :handoff_continue)
        Report.notify(opts)
        next

      {:error, reason} ->
        for {id, entry} <- next.running, not Map.has_key?(previous.running, id), do: Task.Supervisor.terminate_child(Aiur.TaskSupervisor, entry.pid)
        alert({:consume_failed, reason}, opts)

        fallback_agents(previous, agents, opts)
    end
  end

  defp adopt_one(agent, {state, outcomes}, record, validation, opts) do
    with {:ok, _} <- validation,
         :ok <- Compatibility.check(agent, record, opts),
         {:ok, saved, budget} <- restore_metadata(agent),
         :ok <- adoption_slot(state, agent["issue_id"], saved),
         {:ok, pid, session} <- start_runner(agent, opts) do
      entry = running_entry(saved, agent, record, pid, session)
      id = agent["issue_id"]
      state = %{state | running: Map.put(state.running, id, entry), claimed: MapSet.put(state.claimed, id)}
      Logger.info("Adopted agent ticket=#{agent["identifier"]} handoff=#{record["handoff_id"]}")
      {restore_budget(state, agent["issue_id"], budget), [outcome(agent, "adopted", nil, entry) | outcomes]}
    else
      {:error, reason} ->
        Logger.warning("Handoff fallback ticket=#{agent["identifier"]} reason=#{inspect(reason)}")
        {state, [outcome(agent, "fallback", reason) | outcomes]}
    end
  rescue
    error ->
      {state, [outcome(agent, "fallback", {:invalid_snapshot, Exception.message(error)}) | outcomes]}
  end

  # Adoption takes a slot under the configured cap like any other start; an
  # agent past it falls back to a checked retry (#4683). The load-reduced
  # effective limit and a launch `--pause` do not stop live agents here.
  defp adoption_slot(state, id, saved) do
    candidate = %{state | running: Map.put(state.running, id, saved)}

    if Slots.used_slots(candidate) > Slots.used_slots(state) and Slots.used_slots(candidate) > Slots.max_concurrent_agent_limit(state),
      do: {:error, :max_concurrent_agents_reached},
      else: :ok
  end

  defp start_runner(agent, opts) do
    recipient = self()
    generation = generation(opts)
    runner = Keyword.get(opts, :runner, &Runner.adopt/4)

    with {:ok, pid} <- Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> runner.(agent, generation, recipient, opts) end) do
      await_runner(pid, Keyword.get(opts, :adoption_timeout, 15_000))
    end
  end

  defp await_runner(pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:handoff_adopted, ^pid, {:ok, session}} ->
        Process.demonitor(ref, [:flush])
        {:ok, pid, session}

      {:handoff_adopted, ^pid, {:error, reason}} ->
        Process.demonitor(ref, [:flush])
        {:error, reason}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:runner_exit, reason}}
    after
      timeout ->
        Task.Supervisor.terminate_child(Aiur.TaskSupervisor, pid)
        Process.demonitor(ref, [:flush])
        {:error, :adoption_timeout}
    end
  end

  defp running_entry(saved, agent, record, pid, session) do
    saved
    |> Map.merge(%{pid: pid, ref: Process.monitor(pid), adopted_from: record["handoff_id"], workspace_path: agent["workspace"]})
    |> Map.put(:last_codex_timestamp, DateTime.utc_now())
    |> Map.put(:codex_app_server_pid, get_in(session, [:metadata, :codex_app_server_pid]) || (get_in(agent, ["transport", "provider_pid"]) || get_in(agent, ["transport", "os_pid"])))
  end

  defp restore_metadata(agent) do
    entry = Runner.decode(agent["running_entry"])
    budget = if is_binary(agent["dispatch_attempts"]), do: Runner.decode(agent["dispatch_attempts"])
    if is_map(entry) and is_binary(agent["issue_id"]), do: {:ok, entry, budget}, else: {:error, :invalid_snapshot}
  rescue
    _ -> {:error, :invalid_snapshot}
  end

  defp restore_budget(state, _id, nil), do: state
  defp restore_budget(state, id, budget), do: put_in(state.dispatch_recovery.codex_thrash_budget[id], budget)

  defp stop_fallback_agent(agent, opts) do
    stop = Keyword.get(opts, :stop_agent, &Fallback.stop/1)
    stop.(agent)
    Fallback.restore_ownership(agent, opts)
  end

  defp fallback_agents(state, [], _opts), do: state

  defp fallback_agents(state, agents, opts) do
    Enum.each(agents, &stop_fallback_agent(&1, opts))
    ids = agents |> Enum.map(& &1["issue_id"]) |> Enum.filter(&is_binary/1)
    fetch = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    fetched =
      case fetch.(ids) do
        {:ok, issues} when is_list(issues) -> {:ok, Map.new(issues, &{&1.id, &1})}
        {:error, reason} -> {:error, reason}
        result -> {:error, {:invalid_issue_state_result, result}}
      end

    Enum.reduce(agents, state, fn agent, current ->
      case fetched do
        {:ok, issues} ->
          fallback_one(agent, Map.get(issues, agent["issue_id"]), current)

        {:error, reason} ->
          Logger.warning("Handoff fallback deferred ticket=#{agent["identifier"]} reason=#{inspect(reason)}")
          current
      end
    end)
  rescue
    error ->
      Logger.warning("Handoff fallback state lookup failed: #{Exception.message(error)}")
      state
  catch
    kind, reason ->
      Logger.warning("Handoff fallback state lookup failed: #{inspect({kind, reason})}")
      state
  end

  defp fallback_one(agent, %Aiur.Issue{} = issue, state) do
    if DispatchPolicy.retry_candidate_issue?(issue, DispatchPolicy.terminal_state_set()) do
      Fallback.resume(state, Map.update(agent, "issue", %{"state" => issue.state}, &Map.put(&1, "state", issue.state)))
    else
      Logger.info("Handoff fallback skipped non-dispatchable ticket=#{agent["identifier"]} state=#{inspect(issue.state)}")
      state
    end
  end

  defp fallback_one(agent, nil, state) do
    Logger.info("Handoff fallback skipped ticket no longer present identifier=#{agent["identifier"]}")
    state
  end

  defp generation(opts) do
    case Keyword.fetch(opts, :generation) do
      {:ok, generation} ->
        generation

      :error ->
        {:ok, root} = Paths.runtime_state_dir()
        RelayPort.next_generation(Path.join(root, "agent-relays"))
    end
  end

  defp outcome(agent, status, reason, entry \\ %{}) do
    pid = get_in(agent, ["transport", "provider_pid"]) || get_in(agent, ["transport", "os_pid"])

    %{
      identifier: agent["identifier"],
      issue_id: agent["issue_id"],
      status: status,
      reason: if(reason, do: inspect(reason)),
      provider_pid_before: Report.provider_pid(pid),
      provider_pid_after: Report.provider_pid(entry[:codex_app_server_pid]),
      session_id_before: saved_session_id(agent),
      session_id_after: entry[:session_id]
    }
  end

  defp saved_session_id(agent) do
    case Runner.decode(agent["running_entry"]) do
      saved when is_map(saved) -> saved[:session_id]
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp alert(reason, opts) do
    emit = Keyword.get(opts, :emit_alert, &Aiur.Alerts.emit_system/2)

    emit.("system.handoff.incompatible",
      message: "Agent handoff could not be adopted: #{inspect(reason)}",
      reason: "Listed providers fall back to ordinary session resume.",
      needs_attention: true,
      severity: "warning",
      central: true
    )
  end
end
