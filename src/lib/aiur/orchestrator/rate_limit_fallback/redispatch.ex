defmodule Aiur.Orchestrator.RateLimitFallback.Redispatch do
  @moduledoc false

  alias Aiur.{CodingAgent, Config, Issue}
  alias Aiur.Init.AgentCli
  alias Aiur.Orchestrator.{Dispatcher, RateLimitFallback, RemoteControlMode, RetryEngine, State, TicketTransition}

  @spec handoff(keyword(), State.t(), map(), Issue.t(), String.t(), map()) :: {State.t(), boolean()}
  def handoff(opts, state, running_entry, issue, destination, session) do
    teardown = Keyword.get(opts, :teardown_fun, &RemoteControlMode.teardown_for_redispatch/3)
    event = Keyword.get(opts, :handoff_event_fun, &emit_account_handoff/4)
    event.(issue, session.account_name, destination, session.session_id)
    staged_state = teardown.(state, running_entry, :account_handoff)
    staged_entry = Map.get(staged_state.running, issue.id, running_entry)
    safe_entry = redispatch_safety_entry(staged_entry, issue) |> Map.put(:session_execution, %{backend: session.backend, account: destination})
    staged_state = RateLimitFallback.put_running_entry(staged_state, issue.id, safe_entry)

    next_state =
      case Keyword.get(opts, :dispatch_fun) do
        dispatch when is_function(dispatch, 5) ->
          dispatch.(staged_state, issue, nil, Map.get(running_entry, :worker_host),
            account_name: destination,
            resume_thread_id: session.session_id
          )

        _ ->
          Dispatcher.do_dispatch_issue(staged_state, issue, nil, Map.get(running_entry, :worker_host),
            prior_work: Config.agent_prior_work_continuation?(),
            account_name: destination,
            resume_thread_id: session.session_id
          )
      end

    {retain_redispatch_safety(next_state, safe_entry, issue), true}
  end

  defp emit_account_handoff(issue, source, destination, session_id) do
    Aiur.Alerts.emit_system("ticket.#{issue.identifier}.agent.account_handoff",
      issue: issue,
      reason: "Claude session #{session_id} moved from account #{source} to #{destination} and resumed.",
      needs_attention: false,
      severity: "info"
    )
  end

  # Keep the issue on the worker that owns its workspace and session rollout.
  @spec redispatch(State.t(), map(), Issue.t(), keyword()) :: State.t()
  def redispatch(state, running_entry, relabeled_issue, opts) do
    issue_id = relabeled_issue.id
    worker_host = Map.get(running_entry, :worker_host)
    teardown = Keyword.get(opts, :teardown_fun, &RemoteControlMode.teardown_for_redispatch/3)
    dispatch = Keyword.get(opts, :dispatch_fun, &dispatch_prior_work/4)

    # The old entry is the sole owner of the lifecycle fence. Keep a parked
    # copy in `running` until the replacement Task is actually admitted, so a
    # failed fallback never turns an authoritative queue claim into an
    # unfenced, unrecoverable ticket. Dispatcher also carries this context
    # through retries that start after this reconciliation tick.
    staged_entry = redispatch_safety_entry(running_entry, relabeled_issue)

    state =
      state
      |> teardown.(running_entry, :rate_limit_fallback)
      |> RateLimitFallback.put_running_entry(issue_id, staged_entry)

    state = dispatch.(state, relabeled_issue, nil, worker_host)
    state = retain_redispatch_safety(state, staged_entry, relabeled_issue)

    ensure_redispatch_started(state, running_entry, relabeled_issue, worker_host, opts)
  end

  defp redispatch_safety_entry(running_entry, relabeled_issue) do
    safety = %{workspace_path: Map.get(running_entry, :workspace_path)}

    # Do not park a copy of session, pane, or provider-process metadata after
    # teardown: those describe the stopped primary worker, not a retryable
    # fallback entry. Only durable redispatch context is retained.
    running_entry
    |> Map.take([:identifier, :worker_host, :retry_attempt, :prior_work])
    |> Map.merge(%{
      issue: relabeled_issue,
      started_at: Map.get(running_entry, :started_at) || DateTime.utc_now(),
      completion_totals_recorded: false,
      pid: nil,
      ref: nil,
      control: %{status: :completed},
      rate_limit_fallback_replacement: true,
      redispatch_safety: safety
    })
    |> maybe_put_lifecycle_fence(Map.get(running_entry, :lifecycle_fence))
    |> maybe_put_workspace_path(Map.get(safety, :workspace_path))
  end

  # A Task pid is the synchronous admission proof available at this layer.
  # Copy the exact fence, including its generation and concrete queue IDs, to
  # the new entry. If dispatch did not produce a live Task, park the staged
  # entry as completed so it does not consume a slot while RetryEngine retains
  # its claim and retries it.
  defp retain_redispatch_safety(state, staged_entry, relabeled_issue) do
    case Map.get(state.running, relabeled_issue.id) do
      %{pid: pid} = replacement when is_pid(pid) ->
        RateLimitFallback.put_running_entry(state, relabeled_issue.id, inherit_redispatch_safety(replacement, staged_entry))

      _other ->
        RateLimitFallback.put_running_entry(state, relabeled_issue.id, staged_entry)
    end
  end

  defp inherit_redispatch_safety(replacement, staged_entry) do
    replacement
    |> Map.put(:rate_limit_fallback_replacement, true)
    |> Map.put(:redispatch_safety, Map.fetch!(staged_entry, :redispatch_safety))
    |> Map.put(:session_execution, Map.get(replacement, :session_execution) || Map.get(staged_entry, :session_execution))
    |> maybe_put_lifecycle_fence(Map.get(staged_entry, :lifecycle_fence))
    |> maybe_put_workspace_path(Map.get(staged_entry, :workspace_path))
  end

  defp maybe_put_lifecycle_fence(entry, fence) when is_map(fence), do: Map.put(entry, :lifecycle_fence, fence)
  defp maybe_put_lifecycle_fence(entry, _fence), do: entry

  defp maybe_put_workspace_path(entry, path) when is_binary(path), do: Map.put(entry, :workspace_path, path)
  defp maybe_put_workspace_path(entry, _path), do: entry

  defp dispatch_prior_work(state, issue, attempt, worker_host) do
    prior_work? = Config.agent_prior_work_continuation?()
    Dispatcher.do_dispatch_issue(state, issue, attempt, worker_host, prior_work: prior_work?)
  end

  defp ensure_redispatch_started(state, running_entry, issue, worker_host, opts) do
    if live_running_entry?(Map.get(state.running, issue.id)) or
         Map.has_key?(state.retry_attempts, issue.id) do
      state
    else
      schedule_retry = Keyword.get(opts, :schedule_retry_fun, &RetryEngine.schedule_issue_retry/4)
      next_attempt = RetryEngine.next_retry_attempt_from_running(running_entry)

      schedule_retry.(state, issue.id, next_attempt, %{
        identifier: issue.identifier,
        tracker_identity: Issue.tracker_identity(issue),
        error: "backend redispatch did not start",
        prior_work: Config.agent_prior_work_continuation?(),
        worker_host: worker_host,
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    end
  end

  defp live_running_entry?(%{pid: pid}) when is_pid(pid), do: true
  defp live_running_entry?(_entry), do: false

  @spec admission(State.t(), Issue.t(), map(), keyword()) ::
          {:ok, State.t()} | {:error, term(), State.t()}
  def admission(state, issue, running_entry, opts) do
    ready = Keyword.get(opts, :dispatch_ready_fun, &Dispatcher.admit_redispatch/3)

    case ready.(state, issue, Map.get(running_entry, :worker_host)) do
      {:ok, admitted_state} -> {:ok, admitted_state}
      :ok -> {:ok, state}
      {:error, reason, rejected_state} -> {:error, reason, rejected_state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec backend_ready?(String.t() | nil, map(), keyword()) :: boolean()
  def backend_ready?(backend, running_entry, opts) do
    worker_host = Map.get(running_entry, :worker_host)

    ready =
      Keyword.get(opts, :backend_ready_fun, fn candidate, host ->
        default_backend_ready?(candidate, host, opts)
      end)

    is_binary(backend) and backend in CodingAgent.known_backends() and
      ready.(backend, worker_host)
  end

  # A headless fallback spawns on the orchestrator host and cannot use an SSH
  # worker's remote-only workspace, so readiness is only checked there; a
  # worker-hosted entry is left parked rather than moved to a backend that
  # cannot start on that worker. The executable is resolved from the backend's
  # own config (`agent_executable/1`), so any eligible registered fallback works, not
  # just headless claude.
  defp default_backend_ready?(backend, nil, opts) when is_binary(backend) do
    find_executable = Keyword.get(opts, :find_executable_fun, &System.find_executable/1)

    case AgentCli.agent_executable(backend) do
      executable when is_binary(executable) -> is_binary(find_executable.(executable))
      _ -> false
    end
  end

  defp default_backend_ready?(_backend, _worker_host, _opts), do: false

  @spec transition_context(State.t(), map(), Issue.t(), Issue.t(), keyword()) :: map()
  def transition_context(state, running_entry, issue, relabeled, opts) do
    %{
      add_label: Keyword.get(opts, :add_label_fun, &TicketTransition.write_marker(&1, :add, &2, writer: :rate_limit_fallback)),
      identifier: Map.get(running_entry, :identifier),
      issue: issue,
      opts: opts,
      relabeled: relabeled,
      remove_label: Keyword.get(opts, :remove_label_fun, &TicketTransition.write_marker(&1, :remove, &2, writer: :rate_limit_fallback)),
      running_entry: running_entry,
      state: state
    }
  end
end
