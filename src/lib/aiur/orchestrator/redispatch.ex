defmodule Aiur.Orchestrator.Redispatch do
  @moduledoc false

  alias Aiur.{CodingAgent, Config, Issue}
  alias Aiur.Orchestrator.{Dispatcher, RateLimitFallback, RemoteControlMode, RetryEngine, State, TicketTransition}

  @spec call(State.t(), String.t(), String.t() | nil, keyword()) :: {term(), State.t()}
  def call(%State{} = state, identifier, backend, opts \\ []) do
    case State.find_running_by_identifier(state.running, identifier) do
      %{issue: %Issue{} = issue, pid: pid} = entry when is_pid(pid) ->
        redispatch_running(state, entry, issue, backend, opts)

      _ ->
        {{:error, :not_running}, state}
    end
  end

  defp redispatch_running(state, entry, issue, backend, opts) do
    if is_binary(Map.get(entry, :workspace_path)) do
      prepare_and_replace(state, entry, issue, backend, opts)
    else
      {{:error, :workspace_unavailable}, state}
    end
  end

  defp prepare_and_replace(state, entry, issue, backend, opts) do
    with {:ok, relabeled, label} <- select_backend(issue, backend, opts),
         {:ok, admitted} <- admit(state, relabeled, entry, opts),
         :ok <- write_backend_label(issue, label, opts) do
      replace_running(admitted, entry, relabeled, label, opts)
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp select_backend(issue, nil, opts) do
    select = Keyword.get(opts, :select_backend_fun, &CodingAgent.select_for_dispatch/1)

    case select.(issue) do
      {:ok, selected} -> make_selection(issue, CodingAgent.backend_for(selected), opts)
      {:all_limited, candidates} -> {:error, {:all_limited, candidates}}
    end
  end

  defp select_backend(issue, backend, opts) do
    known = Keyword.get(opts, :known_backends_fun, &CodingAgent.known_backends/0)

    if backend in known.(),
      do: make_selection(issue, backend, opts),
      else: {:error, {:unknown_backend, backend}}
  end

  defp make_selection(issue, backend, opts) do
    known = Keyword.get(opts, :known_backends_fun, &CodingAgent.known_backends/0)

    if backend in known.() do
      label = "model:#{backend}"
      labels = Enum.reject(issue.labels, &selector_label?(&1, opts))
      {:ok, %{issue | labels: labels ++ [label]}, label}
    else
      {:error, {:unknown_backend, backend}}
    end
  end

  defp selector_label?(label, opts) do
    known_fun = Keyword.get(opts, :known_backends_fun, &CodingAgent.known_backends/0)
    normalized = label |> to_string() |> String.downcase()
    spec = String.replace_prefix(normalized, "model:", "")
    known = known_fun.()
    effort_labels = Keyword.get(opts, :effort_labels, &CodingAgent.override_effort_labels/0)

    flag? =
      normalized in ["model:remote", String.downcase(CodingAgent.remote_control_alias_label())] or
        normalized in effort_labels.()

    backend? = spec in known or Enum.any?(known, &String.starts_with?(spec, &1 <> "-"))
    String.starts_with?(normalized, "model:") and backend? and not flag?
  end

  defp admit(state, issue, entry, opts) do
    admit = Keyword.get(opts, :admit_fun, &Dispatcher.admit_redispatch/3)

    case admit.(state, issue, Map.get(entry, :worker_host)) do
      {:ok, admitted} -> {:ok, admitted}
      {:error, reason, _rejected} -> {:error, reason}
    end
  end

  defp write_backend_label(issue, label, opts) do
    write = Keyword.get(opts, :write_marker_fun, &TicketTransition.write_marker/4)
    old = Enum.filter(issue.labels, &selector_label?(&1, opts))

    with :ok <- remove_backend_labels(write, issue.identifier, old),
         :ok <- write.(issue.identifier, :add, label, writer: :redispatch) do
      :ok
    else
      {:error, reason} ->
        Enum.each(old, fn previous -> write.(issue.identifier, :add, to_string(previous), writer: :redispatch) end)
        {:error, {:backend_label_failed, reason}}
    end
  end

  defp remove_backend_labels(write, identifier, labels) do
    Enum.reduce_while(labels, :ok, fn label, :ok ->
      case write.(identifier, :remove, to_string(label), writer: :redispatch) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp replace_running(state, entry, issue, label, opts) do
    staged = safety_entry(entry, issue)
    worker_host = Map.get(entry, :worker_host)
    teardown = Keyword.get(opts, :teardown_fun, &RemoteControlMode.teardown_for_redispatch/3)
    state = teardown.(state, entry, :redispatch)
    staged_state = RateLimitFallback.put_running_entry(state, issue.id, staged)
    metadata = %{forced_backend: String.replace_prefix(label, "model:", "")}

    dispatch = Keyword.get(opts, :dispatch_fun, &Dispatcher.do_dispatch_issue/5)

    dispatch_state =
      dispatch.(staged_state, issue, nil, worker_host,
        prior_work: Config.agent_prior_work_continuation?(),
        forced_backend: metadata.forced_backend,
        workspace_path: staged.workspace_path,
        redispatch_safety: staged.redispatch_safety,
        dispatch_result_fun: fn next -> ensure_started(next, entry, issue, worker_host, metadata, opts) end
      )

    {{:ok, :redispatched}, dispatch_state}
  end

  defp safety_entry(entry, issue) do
    safety = %{workspace_path: entry.workspace_path}

    entry
    |> Map.take([:identifier, :worker_host, :retry_attempt, :prior_work, :lifecycle_fence])
    |> Map.merge(%{
      issue: issue,
      started_at: Map.get(entry, :started_at) || DateTime.utc_now(),
      pid: nil,
      ref: nil,
      control: %{status: :completed},
      redispatch_safety: safety,
      workspace_path: safety.workspace_path
    })
  end

  defp ensure_started(state, entry, issue, worker_host, metadata, opts) do
    if live?(Map.get(state.running, issue.id)) or Map.has_key?(state.retry_attempts, issue.id) do
      state
    else
      schedule_retry = Keyword.get(opts, :schedule_retry_fun, &RetryEngine.schedule_issue_retry/4)

      schedule_retry.(state, issue.id, RetryEngine.next_retry_attempt_from_running(entry), %{
        identifier: issue.identifier,
        tracker_identity: Issue.tracker_identity(issue),
        error: "backend redispatch did not start",
        prior_work: Config.agent_prior_work_continuation?(),
        worker_host: worker_host,
        workspace_path: Map.get(entry, :workspace_path),
        forced_backend: metadata.forced_backend
      })
    end
  end

  defp live?(%{pid: pid}) when is_pid(pid), do: Process.alive?(pid)
  defp live?(_), do: false
end
