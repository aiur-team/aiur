defmodule Aiur.Orchestrator.BlockerPropagation do
  @moduledoc "Debounced, bounded propagation along direct blocker push edges; retries share the same queue and cap."
  require Logger
  alias Aiur.{BuildQueue, Config, Issue, Tracker}
  alias Aiur.Events.{BranchRefStore, Publisher}
  alias Aiur.Orchestrator.{PushRouting, RestackScheduler, State, TrackerTasks}
  alias Aiur.Stacking.StackBaseEvidence
  alias Aiur.Workspace.Restack
  @debounce_ms 2_000
  @cap 2

  @spec pushed(State.t(), String.t(), map(), keyword()) :: State.t()
  def pushed(state, blocker, event, opts \\ []) do
    payload = Map.get(event, :payload, event)
    metadata = PushRouting.validated_unblock_metadata(blocker, event)

    if metadata && not Map.get(payload, :superseded, false) do
      push = Map.merge(metadata, %{previous_sha: Map.get(payload, :previous_sha), blocker: blocker})
      state = supersede(state, blocker, push)
      Enum.reduce(Map.values(state.last_polled_issues), state, &enqueue(&2, &1, push, opts))
    else
      state
    end
  end

  defp supersede(state, blocker, push) do
    ids = for issue <- Map.values(state.last_polled_issues), to_string(issue.identifier) == blocker, do: issue.id
    state = Enum.reduce(ids, state, &TrackerTasks.cancel(&2, {:propagate, &1}))

    pending =
      Map.new(state.blocker_propagations, fn {key, job} ->
        {key, if(job.issue.id in ids, do: %{job | head: push.sha, due: now(job.opts) + @debounce_ms}, else: job)}
      end)

    if ids != [] and map_size(pending) > 0, do: Process.send_after(self(), :propagate_blocker_tick, @debounce_ms)
    %{state | blocker_propagations: pending}
  end

  defp enqueue(state, issue, push, opts) do
    blockers = Keyword.get(opts, :blockers, &StackBaseEvidence.blocker_facts/1).(to_string(issue.identifier))
    blocker = Enum.find(blockers, &(&1.id == push.blocker))

    with true <- idle?(state, issue) and enabled?(issue, opts),
         %{pr: %{state: :open, number: number}} <- blocker,
         {:ok, %{state: :open, head_ref: branch, head_sha: head}} <- Keyword.get(opts, :read_pr, &Tracker.ticket_pull_request/1).(to_string(issue.identifier)),
         true <- is_binary(branch) and is_binary(head) do
      replace(state, issue, %{push: push, number: number, branch: branch, head: head, opts: opts})
    else
      _ -> state
    end
  end

  defp replace(state, issue, job) do
    if match?(%{push: push} when push == job.push, state.blocker_propagations[{issue.id, job.push.blocker}]) do
      state
    else
      state = cancel_upstream(state, issue.id, job.push.blocker)
      Process.send_after(self(), :propagate_blocker_tick, @debounce_ms)
      job = Map.merge(job, %{issue: issue, due: now(job.opts) + @debounce_ms})
      %{state | blocker_propagations: Map.put(state.blocker_propagations, {issue.id, job.push.blocker}, job)}
    end
  end

  defp cancel_upstream(state, id, blocker) do
    if Enum.any?(state.tracker_tasks, fn {_ref, task} -> task.key == {:propagate, id} and Map.get(task, :blocker) == blocker end), do: TrackerTasks.cancel(state, {:propagate, id}), else: state
  end

  @spec flush(State.t(), integer() | nil) :: State.t()
  def flush(state, at \\ nil) do
    active = Enum.count(state.tracker_tasks, fn {_ref, job} -> match?({:propagate, _}, job.key) end)

    state.blocker_propagations
    |> Enum.filter(fn {{id, _blocker}, job} -> job.due <= (at || now(job.opts)) and not TrackerTasks.running?(state, {:propagate, id}) end)
    |> Enum.sort_by(fn {id, job} -> {job.due, id} end)
    |> Enum.take(max(@cap - active, 0))
    |> Enum.reduce(state, fn {key, job}, acc -> start(acc, key, job) end)
  end

  defp start(state, {id, _blocker} = key, job) do
    if TrackerTasks.running?(state, {:propagate, id}), do: state, else: start_available(state, key, job)
  end

  defp start_available(state, {id, _blocker} = key, job) do
    state = %{state | blocker_propagations: Map.delete(state.blocker_propagations, key)}
    issue = Map.get(state.last_polled_issues, id, job.issue)

    if Map.has_key?(job, :report) do
      report(state, %{job | issue: issue})
    else
      start_git(state, issue, job)
    end
  end

  defp start_git(state, issue, job) do
    cond do
      TrackerTasks.running?(state, {:restack, issue.id}) -> retry(state, job)
      idle?(state, issue) and enabled?(issue, job.opts) -> start_task(state, issue, job)
      true -> state
    end
  end

  defp start_task(state, issue, job) do
    job = %{job | head: latest_head(issue, job.branch, job.head, job.opts), issue: issue}
    run = Keyword.get(job.opts, :run, &run/1)
    state = TrackerTasks.start(state, {:propagate, issue.id}, fn -> run.(job) end, fn current, result -> complete(current, job, result) end)
    %{state | tracker_tasks: Map.new(state.tracker_tasks, fn {ref, task} -> {ref, if(task.key == {:propagate, issue.id}, do: Map.put(task, :blocker, job.push.blocker), else: task)} end)}
  end

  defp idle?(state, %Issue{} = issue), do: not Map.has_key?(state.running, issue.id) and issue.state not in ["done", "closed", "cancelled", "canceled", "rework", "error"]

  defp run(job) do
    opts = [
      operation: fn workspace, lease ->
        Restack.propagate(workspace, job.branch, job.number, job.push, ownership: lease, dependent_head: job.head, before_push: fn -> fresh(job) end)
      end
    ]

    RestackScheduler.run(job.issue, job.branch, %{number: job.number, sha: job.push.sha}, Config.base_branch(), opts)
  end

  defp latest_head(issue, branch, fallback, opts) do
    case Keyword.get(opts, :latest, &BranchRefStore.latest/1).(issue.identifier) do
      %{ref: ref, sha: sha} when ref == "refs/heads/" <> branch -> sha
      _ -> fallback
    end
  end

  defp fresh(job) do
    if BranchRefStore.latest(job.push.blocker) == Map.take(job.push, [:ref, :sha]) and
         BranchRefStore.latest(job.issue.identifier) in [nil, %{ref: "refs/heads/#{job.branch}", sha: job.head}] do
      :ok
    else
      {:error, :superseded}
    end
  end

  defp complete(state, job, {:ok, {:pushed, sha}}) do
    publish = Keyword.get(job.opts, :publish, &Publisher.publish/2)
    publish.("ticket.#{job.issue.identifier}.branch.push", %{ref: "refs/heads/#{job.branch}", sha: sha, previous_sha: job.head, source: :system})
    finish(state)
  end

  defp complete(state, job, {kind, paths}) when kind in [:conflict, :rewrite, :history_unavailable] do
    reason = "upstream_#{kind}"
    job = Map.put(job, :report, %{paths: paths, reason: reason, steps: []})
    report(state, job)
  end

  defp complete(state, job, {:report_failed, _reason, paths, steps}) do
    retry(state, %{job | report: %{job.report | paths: paths, steps: steps}})
  end

  defp complete(state, job, {:error, reason}) when reason in [:remote_moved, :stale_evidence, :push_failed] do
    retry(state, job)
  end

  defp complete(state, job, {:error, {:workspace_owned, _owner}}), do: retry(state, job)
  defp complete(state, job, {:error, {:git_failed, _command}}), do: retry(state, job)

  defp complete(state, job, result) do
    Logger.info("Blocker propagation result issue=#{job.issue.identifier} blocker=#{job.push.blocker}: #{inspect(result)}")
    finish(state)
  end

  defp report(state, job) do
    report = Keyword.get(job.opts, :report, &RestackScheduler.report_conflict/4)
    opts = [reason: job.report.reason, completed_steps: job.report.steps]
    TrackerTasks.start(state, {:propagate, job.issue.id}, fn -> report.(job.issue, job.number, job.report.paths, opts) end, fn current, result -> complete(current, job, result) end)
  end

  defp retry(state, job) do
    Process.send_after(self(), :propagate_blocker_tick, @debounce_ms)
    pending = Map.put_new(state.blocker_propagations, {job.issue.id, job.push.blocker}, %{job | due: now(job.opts) + @debounce_ms})
    %{state | blocker_propagations: pending}
  end

  defp finish(state) do
    send(self(), :propagate_blocker_tick)
    state
  end

  defp now(opts), do: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end).()

  defp enabled?(issue, opts) do
    case Keyword.fetch(opts, :enabled) do
      {:ok, enabled} -> enabled
      :error -> enabled_by_settings?(issue)
    end
  end

  defp enabled_by_settings?(issue) do
    case Config.settings() do
      {:ok, %{tracker: tracker}} -> enabled_for?(tracker, to_string(issue.identifier), &BuildQueue.show/0)
      _ -> false
    end
  end

  @doc false
  @spec enabled_for?(map(), String.t(), (-> map())) :: boolean()
  def enabled_for?(%{kind: "github", propagate_blocker_pushes: value}, _identifier, _queues) when is_boolean(value), do: value
  def enabled_for?(%{kind: "github"}, identifier, queues), do: optimistic_queue?(identifier, queues.())
  def enabled_for?(_tracker, _identifier, _queues), do: false

  @doc false
  @spec optimistic_queue?(String.t(), map()) :: boolean()
  def optimistic_queue?(identifier, %{queues: queues}) do
    Enum.any?(queues, fn queue ->
      queue.start_trigger in [:pr_opened, :pr_ci_green, :pr_approved] and Enum.any?(queue.items, &(to_string(&1.number) == identifier))
    end)
  end
end
