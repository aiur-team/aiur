defmodule Aiur.Orchestrator.RestackScheduler do
  @moduledoc "Schedules idle dependent restacks from delivered blocker facts."
  require Logger
  alias Aiur.{Config, Issue, Tracker}
  alias Aiur.Events.{BranchRefStore, Publisher}
  alias Aiur.Orchestrator.{State, TicketTransition, TrackerTasks}
  alias Aiur.Stacking.StackBaseEvidence
  alias Aiur.Workspace.{HostLock, Layout, Ownership, Restack}

  @spec merged(State.t(), String.t(), map()) :: State.t()
  def merged(state, blocker, event) do
    pr = Map.get(event, :pr, %{})
    facts = %{id: blocker, pr: %{merged?: true, number: pr["number"], merge_commit_sha: pr["merge_commit_sha"]}}
    reconcile(state, Map.values(state.last_polled_issues), merged: facts)
  end

  @spec reconcile(State.t(), [Issue.t()], keyword()) :: State.t()
  def reconcile(state, issues, opts \\ []) do
    if enabled?(opts) and not Map.has_key?(state.restack_completed, :unsupported_git) do
      state |> retry_reports(opts) |> then(&Enum.reduce(issues, &1, fn issue, acc -> schedule_issue(acc, issue, opts) end))
    else
      state
    end
  end

  defp retry_reports(state, opts) do
    Enum.reduce(state.restack_completed, state, fn
      {key, %{issue: issue, number: number, paths: paths, steps: steps}}, acc ->
        retry_report(acc, issue, key, number, paths, steps, opts)

      _, acc ->
        acc
    end)
  end

  defp retry_report(state, issue, key, number, paths, steps, opts) do
    if TrackerTasks.running?(state, {:restack, issue.id}) do
      state
    else
      TrackerTasks.start(state, {:restack, issue.id}, fn -> report_conflict(issue, number, paths, Keyword.put(opts, :completed_steps, steps)) end, fn current, result ->
        complete(current, issue, key, number, result, opts)
      end)
    end
  end

  defp schedule_issue(state, %Issue{} = issue, opts) do
    if Map.has_key?(state.running, issue.id) or TrackerTasks.running?(state, {:restack, issue.id}) or
         issue.state in ["done", "closed", "cancelled", "canceled"] do
      state
    else
      read_pr = Keyword.get(opts, :read_pr, &Tracker.ticket_pull_request/1)
      {:ok, pr} = read_pr.(to_string(issue.identifier))
      branch = branch(pr, issue, opts)
      blockers = Keyword.get(opts, :blockers, &StackBaseEvidence.blocker_facts/1).(to_string(issue.identifier))
      blockers = merge_event_facts(blockers, issue, opts[:merged])
      opts = Keyword.put(opts, :dependent_head, dependent_head(pr, issue, opts))
      Enum.reduce(blockers, state, fn blocker, acc -> schedule(acc, issue, branch, blocker, opts) end)
    end
  end

  defp schedule(state, issue, branch, %{pr: %{merged?: true, number: number, merge_commit_sha: sha}}, opts)
       when is_binary(branch) and branch != "" and is_integer(number) and is_binary(sha) and sha != "" do
    key = {issue.id, sha, opts[:dependent_head]}

    if state.restack_completed[key] == :done or TrackerTasks.running?(state, {:restack, issue.id}) do
      state
    else
      base = Config.base_branch(opts)
      run = Keyword.get(opts, :run, &run/4)

      TrackerTasks.start(
        state,
        {:restack, issue.id},
        fn -> run.(issue, branch, %{number: number, sha: sha}, base) end,
        fn current, result -> complete(current, issue, key, number, result, opts) end
      )
    end
  end

  defp schedule(state, _issue, _branch, _blocker, _opts), do: state

  defp complete(state, issue, key, number, {:conflict, paths}, opts) do
    report = Keyword.get(opts, :report, fn issue, number, paths -> report_conflict(issue, number, paths, opts) end)

    TrackerTasks.start(state, {:restack, issue.id}, fn -> report.(issue, number, paths) end, fn current, result ->
      complete(current, issue, key, number, result, opts)
    end)
  end

  defp complete(state, issue, key, number, {:report_failed, reason, paths, steps}, _opts) do
    Logger.warning("Restack conflict reporting deferred: #{inspect(reason)}")
    %{state | restack_completed: Map.put(state.restack_completed, key, %{issue: issue, number: number, paths: paths, steps: steps})}
  end

  defp complete(state, issue, key, number, {:ok, result}, _opts) do
    Logger.info("Restack complete: issue=#{issue.identifier} blocker_pr=#{number} result=#{inspect(result)}")
    %{state | restack_completed: Map.put(state.restack_completed, key, :done)}
  end

  defp complete(state, _issue, _key, _number, {:error, :unsupported_git}, _opts) do
    Logger.warning("Automatic restacking disabled: git 2.40 or newer is required")
    %{state | restack_completed: Map.put(state.restack_completed, :unsupported_git, :done)}
  end

  defp complete(state, issue, _key, number, result, _opts) do
    Logger.warning("Restack skipped: issue=#{issue.identifier} blocker_pr=#{number} result=#{inspect(result)}")
    state
  end

  defp run(issue, branch, blocker, base) do
    identifier = to_string(issue.identifier)

    with {:ok, workspace} <- Layout.workspace_path_for_issue(Layout.safe_identifier(identifier), nil),
         true <- File.dir?(Path.join(workspace, ".git")) or File.regular?(Path.join(workspace, ".git")),
         {:ok, lease} <- Ownership.claim(identifier) do
      try do
        run_locked(workspace, identifier, lease, branch, blocker, base)
      after
        Ownership.release_and_wait(lease)
      end
    else
      false -> {:error, :workspace_missing}
      error -> error
    end
  end

  defp run_locked(workspace, identifier, lease, branch, blocker, base) do
    with {:ok, lock} <- HostLock.acquire(workspace, identifier),
         :ok <- HostLock.handoff_to_ownership(lock, lease) do
      Restack.run(workspace, branch, blocker.number, base, blocker.sha, ownership: lease)
    end
  end

  @doc false
  @spec report_conflict(Issue.t(), pos_integer(), [String.t()], keyword()) :: {:ok, :conflict_reported} | {:report_failed, term(), [String.t()], [atom()]}
  def report_conflict(issue, number, paths, opts \\ []) do
    payload = %{reason: "restack_conflict", blocker_pr: number, paths: paths}

    body =
      "Restack conflict after blocker PR ##{number} merged (reason: restack_conflict).\n\nConflicted paths:\n" <>
        Enum.map_join(paths, "\n", &"- `#{&1}`") <>
        "\n\nResolve using the agent skill’s ‘After the blocker merges: restack’ recipe, then push and request fresh review. Nothing was pushed."

    write = Keyword.get(opts, :write_state, &TicketTransition.write_state/3)
    comment = Keyword.get(opts, :comment, &Tracker.create_comment/2)
    publish = Keyword.get(opts, :publish, &Publisher.publish/2)

    steps = [
      state: fn -> write.(issue.id, "rework", writer: :restack, expected_state: issue.state) end,
      comment: fn -> comment.(issue.id, body) end,
      event: fn -> publish.("ticket.#{issue.identifier}.restack.conflict", payload) end
    ]

    Enum.reduce_while(steps, {:ok, Keyword.get(opts, :completed_steps, [])}, fn step, {:ok, completed} -> report_step(step, completed, paths) end)
    |> case do
      {:ok, _steps} -> {:ok, :conflict_reported}
      failure -> failure
    end
  end

  defp report_step({name, action}, completed, paths) do
    case if(name in completed, do: :ok, else: action.()) do
      {:error, reason} -> {:halt, {:report_failed, reason, paths, completed}}
      _success -> {:cont, {:ok, Enum.uniq([name | completed])}}
    end
  end

  defp dependent_head(nil, issue, opts) do
    case Keyword.get(opts, :branch, &BranchRefStore.latest/1).(issue.identifier) do
      %{sha: sha} -> sha
      _ -> nil
    end
  end

  defp dependent_head(pr, _issue, _opts), do: Map.get(pr, :head_sha)

  defp branch(%{state: :open, head_ref: ref}, _issue, _opts) when is_binary(ref), do: ref

  defp branch(nil, issue, opts) do
    case Keyword.get(opts, :branch, &BranchRefStore.latest/1).(issue.identifier) do
      %{ref: "refs/heads/" <> ref} -> ref
      _ -> nil
    end
  end

  defp branch(_pr, _issue, _opts), do: nil

  defp merge_event_facts(blockers, issue, %{id: id} = merged) do
    if Enum.any?(issue.blocked_by, &(to_string(Map.get(&1, :id)) == id)) or Enum.any?(blockers, &(&1.id == id)), do: [merged | Enum.reject(blockers, &(&1.id == id))], else: blockers
  end

  defp merge_event_facts(blockers, _issue, _merged), do: blockers

  defp enabled?(opts) do
    case Keyword.fetch(opts, :enabled) do
      {:ok, value} -> value
      :error -> match?({:ok, %{tracker: %{kind: "github", restack_after_blocker_merge: true}}}, Config.settings())
    end
  end
end
