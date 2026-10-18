defmodule Aiur.MainWatch do
  @moduledoc "Durable base-branch CI observations; network reads run outside the control server."
  use GenServer
  require Logger
  alias Aiur.Config
  alias Aiur.Events
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.{ResourceStore, Transport}
  alias Aiur.MainWatch.{Canary, Fixer, GitHub, Persistence, State, Suspects}
  alias Aiur.MergePolicy

  @request_limit 64

  @spec enabled?() :: boolean()
  def enabled?, do: MergePolicy.current().main_watch.enabled

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec reconcile() :: :ok
  def reconcile do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :reconcile)
    :ok
  end

  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__) do
    GenServer.call(server, :state)
  catch
    :exit, {:noproc, _} -> %{watcher: :not_running, status: :unknown, red_since: nil}
    :exit, _ -> %{watcher: :unavailable, status: :unknown, red_since: nil, unavailable: true}
  end

  @spec inherited?(String.t(), String.t(), GenServer.server()) :: atom()
  def inherited?(check, merge_base, server \\ __MODULE__) do
    GenServer.call(server, {:inherited, check, merge_base})
  catch
    :exit, _ -> :unknown
  end

  @impl true
  def init(opts) do
    config = Keyword.get_lazy(opts, :config, fn -> MergePolicy.current().main_watch end)
    branch = Keyword.get_lazy(opts, :branch, &Config.base_branch/0)
    repo = Keyword.get_lazy(opts, :repo, &GitHubConfig.repo/0)
    interval = Keyword.get_lazy(opts, :interval_ms, fn -> Config.settings!().polling.interval_seconds * 1_000 end)
    subscribe = Keyword.get(opts, :subscribe, true)
    if subscribe, do: Events.subscribe("system.#{branch}.branch.push")
    if subscribe, do: Events.subscribe("system.pr.merged")
    data = Keyword.get(opts, :load_fun, &Persistence.load/2).(repo, branch)
    send(self(), :poll)
    {:ok, %{data: data, config: config, branch: branch, repo: repo, interval: interval, opts: opts, task: nil, dirty: false, debounce: nil}}
  end

  @impl true
  def handle_call(:state, _from, server) do
    watcher = if server.data.unavailable, do: :unavailable, else: :running

    state =
      server.data.state
      |> Map.put(:unavailable, server.data.unavailable)
      |> Map.put(:watcher, watcher)
      |> Map.put(:last_error, Map.get(server.data, :last_error))
      |> Map.put(:merge_groups, Map.get(server.data, :merge_groups, []))

    {:reply, state, server}
  end

  def handle_call({:inherited, check, base}, _from, server) do
    now = Keyword.get(server.opts, :now_fun, fn -> System.system_time(:millisecond) end).()
    state = State.record_history(server.data.state, %{checks: [], completed_at: nil}, now)
    {:reply, State.inherited?(state, check, base, server.data.commits), server}
  end

  @impl true
  def handle_cast(:reconcile, server), do: {:noreply, schedule_reconcile(server)}

  @impl true
  def handle_info(:poll, server) do
    Process.send_after(self(), :poll, server.interval)
    {:noreply, start_poll(server)}
  end

  def handle_info({:event, %{topic: "system.pr.merged"} = payload}, server) do
    merges = [payload | server.data.early_merges] |> Enum.take(200)
    data = %{server.data | early_merges: merges}
    {:noreply, save(%{server | data: data})}
  end

  def handle_info({:event, _event}, server), do: {:noreply, schedule_reconcile(server)}

  def handle_info(:reconcile_due, server), do: {:noreply, start_poll(%{server | debounce: nil})}

  def handle_info({ref, {capability, result}}, %{task: %{ref: ref}} = server) do
    Process.demonitor(ref, [:flush])
    next = consume(result, %{server | task: nil, opts: Keyword.put(server.opts, :actions_write, capability)})
    {:noreply, if(next.dirty, do: schedule_reconcile(%{next | dirty: false}), else: next)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = server) do
    Logger.warning("main-watch poll failed: #{inspect(reason)}")
    next = consume({:error, {:poll_crashed, reason}}, %{server | task: nil})
    {:noreply, if(next.dirty, do: schedule_reconcile(%{next | dirty: false}), else: next)}
  end

  def handle_info(_message, server), do: {:noreply, server}

  defp schedule_reconcile(%{debounce: nil} = server) do
    delay = Keyword.get(server.opts, :debounce_ms, 2_000)
    %{server | debounce: Process.send_after(self(), :reconcile_due, delay)}
  end

  defp schedule_reconcile(server), do: server

  defp start_poll(%{task: task} = server) when not is_nil(task), do: %{server | dirty: true}

  defp start_poll(server) do
    poll = Keyword.get(server.opts, :poll_fun, &GitHub.poll/3)

    opts =
      server.opts
      |> Keyword.put(:history, server.data.state.history)
      |> Keyword.put(:commit_etag, Map.get(server.data, :commit_etag))
      |> Keyword.put(:commits, Map.get(server.data, :commit_window, server.data.commits))
      |> Keyword.put(:commit_dates, Map.get(server.data, :commit_dates, []))
      |> bounded_requests()

    task =
      Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn ->
        capability = Keyword.get_lazy(opts, :actions_write, fn -> GitHub.actions_write?(opts) end)

        result =
          case poll.(server.branch, server.config.workflows, Keyword.put(opts, :actions_write, capability)) do
            {:ok, result} -> {:ok, prepare(result, %{server | opts: opts})}
            error -> error
          end

        {capability, result}
      end)

    %{server | task: task}
  end

  defp bounded_requests(opts) do
    count = :atomics.new(1, [])
    request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

    Keyword.put(opts, :request_fun, fn call ->
      if :atomics.add_get(count, 1, 1) <= @request_limit, do: request.(call), else: {:error, :main_watch_request_limit}
    end)
  end

  defp prepare(result, server) do
    now = Keyword.get(server.opts, :now_fun, fn -> System.system_time(:millisecond) end).()
    {older, latest} = Enum.split(result.observations, -1)
    state = Enum.reduce(older, server.data.state, &State.record_history(&2, &1, now))
    suspects = Keyword.get(server.opts, :suspects_fun, &Suspects.fetch/5)

    latest =
      Enum.map(latest, fn observation ->
        if observation.sha == state.sha or Enum.all?(observation.checks, &(&1.conclusion in ~w(success neutral skipped))) do
          observation
        else
          Map.put(observation, :suspect_merges, suspects.(state.last_green_sha, observation.sha, result.commits, server.data.early_merges, server.opts))
        end
      end)

    fixer_latest = Enum.map(latest, &Map.put(&1, :last_green_sha, state.last_green_sha))
    # Filing errors raise their own attention and retry next poll; CI observations still advance.
    Fixer.reconcile(older ++ fixer_latest, server.config, server.opts)

    completed = completed_at(result, server.data)

    decision = Canary.decide(completed, result.runs, server.config.canary_minutes, result.actions_write, now, List.first(result.commits))
    window = max(server.config.canary_minutes * 60_000, 1)
    allowed = is_nil(server.data.canary_at) or now - server.data.canary_at >= window

    outcome =
      case {decision, allowed} do
        {{:rerun, id}, true} -> rerun(id, "#{server.branch}:canary", now, window, server)
        {{:attention, reason}, true} -> {:error, reason}
        _ -> :ok
      end

    flake_events = flake_rerun(latest, state, result, now, server) ++ single_test_rerun(latest, state, result, now, server)
    result |> Map.put(:observations, older ++ latest) |> Map.put(:canary_outcome, outcome) |> Map.put(:flake_events, flake_events)
  end

  defp rerun(id, scope, now, window, server) do
    with :ok <- Persistence.reserve_rerun(server.repo, scope, now, window) do
      Keyword.get(server.opts, :rerun_fun, &GitHub.rerun/2).(id, server.opts)
    end
  end

  defp completed_at(result, data) do
    times =
      result.runs
      |> Enum.filter(&(&1.status == "completed" and &1.conclusion in ~w(success failure timed_out action_required startup_failure)))
      |> Enum.map(&Map.get(&1, :completed_at))
      |> Enum.filter(&is_integer/1)

    times = times ++ Enum.map(result.observations, & &1.completed_at)
    times = if data.last_completed_at, do: [data.last_completed_at | times], else: times
    Enum.max(times, fn -> data.started_at end)
  end

  defp flake_rerun([observation], state, result, now, server) do
    {_next, events} = State.observe(state, observation, now)

    if Enum.any?(events, &(elem(&1, 0) == "system.main.ci.flaked")) do
      runs = Enum.filter(result.runs, &(&1.sha == observation.sha and &1.conclusion == "failure"))

      outcome = flake_outcome(runs, result.actions_write, now, server)

      [{"system.main.ci.flake_rerun", %{sha: observation.sha, signature: observation.digest.signature, outcome: outcome_payload(outcome), run_urls: observation.run_urls}}]
    else
      []
    end
  end

  defp flake_rerun([], _state, _result, _now, _server), do: []

  defp single_test_rerun([observation], state, result, now, server) do
    runs = failed_runs(observation.sha, result.runs)

    if observation.sha != state.sha and single_test_candidate?(observation, runs) and result.actions_write do
      rerun_if_untouched(observation, runs, now, server)
    else
      []
    end
  end

  defp single_test_rerun([], _state, _result, _now, _server), do: []

  defp failed_runs(sha, runs), do: Enum.filter(runs, &(&1.sha == sha and &1.conclusion == "failure"))

  defp single_test_candidate?(observation, runs) do
    digest = observation.digest
    tests = digest.tests

    digest.test_only and not digest.flake_only and not digest.truncated and single_test_path?(tests) and valid_failed_runs?(runs)
  end

  defp single_test_path?([%{path: path}]), do: is_binary(path) and path != ""
  defp single_test_path?(_tests), do: false

  defp valid_failed_runs?([_ | _] = runs), do: Enum.all?(runs, &(is_integer(&1.id) and &1.id > 0))
  defp valid_failed_runs?(_runs), do: false

  defp rerun_if_untouched(observation, runs, now, server) do
    changed_paths = Keyword.get(server.opts, :changed_paths_fun, &GitHub.changed_paths/2)

    case changed_paths.(observation.sha, server.opts) do
      {:ok, paths} when is_list(paths) -> rerun_if_path_untouched(observation, runs, paths, now, server)
      _ -> []
    end
  end

  defp rerun_if_path_untouched(observation, runs, changed_paths, now, server) do
    if hd(observation.digest.tests).path in changed_paths, do: [], else: rerun_single_test_runs(observation, runs, now, server)
  end

  defp rerun_single_test_runs(observation, runs, now, server) do
    reserve = Keyword.get(server.opts, :reserve_single_test_rerun_fun, &reserve_single_test_rerun/4)

    case reserve.(server.repo, observation.sha, now, server.opts) do
      :ok ->
        rerun = Keyword.get(server.opts, :rerun_failed_jobs_fun, &GitHub.rerun_failed_jobs/2)
        outcome = Enum.map(runs, fn run -> {run.id, rerun.(run.id, server.opts)} end)
        payload = %{sha: observation.sha, signature: observation.digest.signature, outcome: outcome_payload(outcome), run_urls: observation.run_urls}
        [{"system.#{server.branch}.ci.flake_rerun", payload}]

      _ ->
        []
    end
  end

  defp reserve_single_test_rerun(repo, sha, now, _opts) do
    # A commit SHA is immutable; keep its reservation for the maximum supported run lifetime.
    Persistence.reserve_rerun(repo, "single-test:" <> sha, now, 100 * 365 * 24 * 60 * 60_000)
  end

  defp flake_outcome(_runs, false, _now, _server), do: {:error, :actions_write_unavailable}
  defp flake_outcome(runs, true, now, server), do: Enum.map(runs, fn run -> {run.id, rerun(run.id, "#{server.branch}:flake:#{run.id}", now, 7 * 24 * 60 * 60_000, server)} end)

  defp commit_order(current, previous) do
    case Enum.find(current, &(&1 in previous)) do
      nil -> current
      shared -> Enum.uniq(current ++ Enum.drop_while(previous, &(&1 != shared)))
    end
  end

  defp retained_commits(commits, history) do
    shas = MapSet.new(history, & &1.sha)
    oldest = commits |> Enum.with_index() |> Enum.filter(fn {sha, _} -> MapSet.member?(shas, sha) end) |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 19 end)
    Enum.take(commits, max(oldest + 1, 20))
  end

  defp consume({:ok, result}, server) do
    now = Keyword.get(server.opts, :now_fun, fn -> System.system_time(:millisecond) end).()

    data =
      server.data
      |> Map.put(:commits, commit_order(result.commits, server.data.commits))
      |> Map.put(:commit_window, result.commits)
      |> Map.put(:commit_dates, Map.get(result, :commit_dates, []))
      |> Map.put(:commit_etag, Map.get(result, :commit_etag))
      |> Map.put(:merge_groups, Map.get(result, :merge_groups, []))
      |> Map.put(:unavailable, false)
      |> Map.put(:last_error, nil)

    data = observe(data, result.observations, now)
    data = %{data | commits: retained_commits(data.commits, data.state.history)}
    data = %{data | pending: data.pending ++ result.flake_events, last_completed_at: completed_at(result, server.data)}
    data = canary(data, result, now, server)
    save(%{server | data: data, opts: Keyword.put(server.opts, :actions_write, result.actions_write)})
  end

  defp consume({:error, reason}, server) do
    Logger.warning("main-watch reconcile unavailable: #{inspect(reason)}")
    pending = server.data.pending
    event = {"system.main.ci.unavailable", %{reason: inspect(reason)}}

    data =
      if server.data.unavailable do
        Map.put(server.data, :last_error, status_error(reason))
      else
        server.data |> Map.put(:unavailable, true) |> Map.put(:last_error, status_error(reason)) |> Map.put(:pending, pending ++ [event])
      end

    save(%{server | data: data})
  end

  defp status_error({:github, :auth, %{status: 401, caller: caller, credential: credential}}),
    do: "GitHub rejected #{credential} with HTTP 401 during #{caller}"

  defp status_error({:github, :auth, %{status: 401}}), do: "GitHub rejected the configured credential with HTTP 401"
  defp status_error({:github, classification, %{status: status}}) when is_integer(status), do: "GitHub #{classification} (HTTP #{status})"
  defp status_error({:github, classification, _detail}), do: "GitHub #{classification}"
  defp status_error({:poll_crashed, _reason}), do: "poll worker crashed"
  defp status_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp status_error(_reason), do: "poll failed"

  defp observe(data, [], now), do: %{data | state: State.record_history(data.state, %{checks: [], completed_at: nil}, now)}

  defp observe(data, observations, now) do
    {older, [latest]} = Enum.split(observations, -1)
    state = Enum.reduce(older, data.state, &State.record_history(&2, &1, now))
    {state, events} = State.observe(state, latest, now)
    %{data | state: state, pending: data.pending ++ events, last_completed_at: latest.completed_at}
  end

  defp canary(data, result, now, server) do
    minutes = server.config.canary_minutes
    decision = Canary.decide(data.last_completed_at || data.started_at, result.runs, minutes, result.actions_write, now, List.first(result.commits))
    window = max(minutes * 60_000, 1)

    capability_attention = decision == {:attention, :actions_write_unavailable}
    notified = Map.get(data, :canary_permission_notified, false)

    if decision != :noop and not (capability_attention and notified) and (is_nil(data.canary_at) or now - data.canary_at >= window) do
      outcome = Map.get(result, :canary_outcome, {:error, :not_attempted})
      payload = %{window: div(now, window), decision: inspect(decision), outcome: outcome_payload(outcome), run_urls: Enum.map(result.runs, & &1.url)}
      event = {"system.main.ci.canary", payload}
      data |> Map.put(:canary_permission_notified, notified or capability_attention) |> Map.put(:canary_at, now) |> Map.put(:pending, data.pending ++ [event])
    else
      data
    end
  end

  defp save(server) do
    persist = Keyword.get(server.opts, :save_fun, &Persistence.save/3)
    emit = Keyword.get(server.opts, :emit_fun, &emit/2)

    case persist.(server.repo, server.branch, server.data) do
      :ok ->
        remaining = Enum.drop_while(server.data.pending, fn {topic, payload} -> emit.(topic, payload) == :ok end)
        data = %{server.data | pending: remaining}

        case persist.(server.repo, server.branch, data) do
          :ok -> %{server | data: data}
          {:error, _} -> server
        end

      {:error, reason} ->
        Logger.warning("main-watch persistence failed: #{inspect(reason)}")
        server
    end
  end

  defp outcome_payload(:ok), do: %{status: "ok"}
  defp outcome_payload({:error, reason}), do: %{status: "error", reason: inspect(reason)}
  defp outcome_payload(outcomes) when is_list(outcomes), do: Enum.map(outcomes, fn {id, result} -> %{run_id: id, result: outcome_payload(result)} end)

  defp attention?("system.main.ci.flake_rerun", %{outcome: outcome}) when is_list(outcome), do: Enum.any?(outcome, &(&1.result.status != "ok"))
  defp attention?(topic, _payload), do: topic in ["system.main.ci.failed", "system.main.ci.canary", "system.main.ci.unavailable", "system.main.ci.flake_rerun"]

  defp publication_key(topic, payload) do
    id = :crypto.hash(:sha256, :erlang.term_to_binary({topic, payload})) |> Base.encode16(case: :lower)
    ResourceStore.key_for_repo(:main_watch, GitHubConfig.repo(), "publication:" <> id)
  end

  defp emit(topic, payload) do
    Aiur.Alerts.emit_system(topic,
      message: "Base-branch CI: #{topic}",
      durable: true,
      needs_attention: attention?(topic, payload),
      exchange_payload: payload,
      resource: publication_key(topic, payload),
      resource_version: "1",
      resource_source: :poll,
      observation_identity: %{kind: :main_ci, sha: Map.get(payload, :sha)}
    )
  end
end
