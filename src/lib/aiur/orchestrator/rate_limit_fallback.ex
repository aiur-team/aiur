defmodule Aiur.Orchestrator.RateLimitFallback do
  @moduledoc """
  Automatic codex -> claude reroute when a running codex agent hits
  `usage_limit_exhausted`, reverted once `Aiur.ModelAvailability` reports
  codex available again. Config-driven via `Config.rate_limit_fallback_backend/0`
  (`agent.rate_limit_fallback`, default `"claude"`).

  Reuses the same durable `model:<backend>` override label that
  `CodingAgent.backend_for/1` already resolves, plus the exact
  teardown-and-redispatch mechanics `RemoteControlMode` uses for its
  promote/demote toggle — so a fallback survives an aiur restart the same way
  a manual relabel would. A second durable marker label records that the
  override was placed automatically (not by an operator), so only fallbacks
  this module engaged are ever auto-reverted; an operator's own `model:claude`
  label is left untouched. Because the fallback target is the non-resumable
  headless `claude` backend (see `CodingAgent.resumable?/1`), engaging the
  fallback never writes codex's on-disk session handle — reverting resumes
  the original codex rollout for free (as long as the redispatch lands back
  on the same worker host, which `redispatch/3` preserves explicitly).

  Engaging is skipped entirely when the issue already carries an explicit
  `model:<backend>` override label: `CodingAgent.override_backend/1` resolves
  the *first* matching label in list order, so an operator-authored override
  would silently outrank (or, on revert, be mistaken for) our own appended
  label. Treating any pre-existing override as "hands off" avoids that
  ambiguity entirely rather than trying to track and restore it.

  All functions execute inside the orchestrator GenServer process, called
  once per poll tick from `Reconciler.reconcile_running_lifecycle/1`.
  """

  require Logger

  alias Aiur.{CodingAgent, Config, Issue, ModelAvailability, Tracker}
  alias Aiur.Orchestrator.{Dispatcher, RemoteControlMode, State}

  @primary_backend "codex"
  @marker_label_suffix "rate-limit-fallback"

  @spec reconcile(State.t()) :: State.t()
  def reconcile(%State{} = state) do
    # Resolved once per tick, not once per running entry: both hit
    # Config.settings!() (a full changeset parse) or a model-usage.json
    # read, and are constant for the whole pass.
    opts = [
      fallback_backend: Config.rate_limit_fallback_backend(),
      marker_label: marker_label(),
      state: ModelAvailability.load()
    ]

    Enum.reduce(state.running, state, fn {_issue_id, entry}, acc ->
      case entry do
        %{issue: %Issue{} = issue} = running_entry ->
          apply_decision(acc, running_entry, issue, decide(running_entry, issue, opts), opts)

        _ ->
          acc
      end
    end)
  end

  # `opts` is forwarded to `ModelAvailability.available?/2` (accepts `:state`
  # / `:path` / `:now`) and read for `:fallback_backend` / `:marker_label` /
  # `:current_backend` — same inject-for-tests-default-to-live-resolution
  # shape as `CodingAgent.select_for_dispatch/2`, so this decision is
  # unit-testable without a real config file, `model-usage.json`, or ambient
  # `agent.kind`/`agent.routing` config on disk.
  @doc false
  @spec decide(map(), Issue.t(), keyword()) :: :engage | :revert | :noop
  def decide(running_entry, %Issue{} = issue, opts \\ []) do
    marker_label = Keyword.get_lazy(opts, :marker_label, &marker_label/0)

    cond do
      fallback_engaged?(issue, marker_label) ->
        if revert_ready?(running_entry) and ModelAvailability.available?(@primary_backend, opts),
          do: :revert,
          else: :noop

      usage_limited_on_primary?(running_entry, issue, opts) ->
        :engage

      true ->
        :noop
    end
  end

  @doc false
  @spec fallback_engaged?(Issue.t(), String.t()) :: boolean()
  def fallback_engaged?(%Issue{} = issue, marker_label \\ marker_label()),
    do: marker_label in Issue.label_names(issue)

  defp usage_limited_on_primary?(running_entry, issue, opts) do
    fallback_backend = Keyword.get_lazy(opts, :fallback_backend, &Config.rate_limit_fallback_backend/0)
    current_backend = Keyword.get_lazy(opts, :current_backend, fn -> CodingAgent.backend_for(issue) end)

    State.paused_running_entry?(running_entry) and
      Map.get(running_entry, :paused_reason) == :usage_limit_exhausted and
      is_binary(fallback_backend) and
      is_nil(CodingAgent.override_backend(issue)) and
      current_backend == @primary_backend
  end

  # Only revert while the entry is actively working, or paused for the exact
  # reason this module cares about (claude itself hit a usage limit while the
  # fallback was engaged). Any OTHER pause reason (an operator's explicit
  # pause, a duration cap, a CI wait, ...) means something else is
  # deliberately holding the agent, and an automatic revert must not silently
  # tear that down — mirrors the narrow allowlist
  # `PauseResume.maybe_auto_resume_spurious_worker_pause/3` already uses for
  # which pause reasons are safe to auto-act on.
  defp revert_ready?(running_entry) do
    not State.paused_running_entry?(running_entry) or
      Map.get(running_entry, :paused_reason) == :usage_limit_exhausted
  end

  defp apply_decision(state, _running_entry, _issue, :noop, _opts), do: state

  defp apply_decision(state, running_entry, issue, :engage, opts) do
    fallback_backend = Keyword.get_lazy(opts, :fallback_backend, &Config.rate_limit_fallback_backend/0)
    marker_label = Keyword.get_lazy(opts, :marker_label, &marker_label/0)
    identifier = Map.get(running_entry, :identifier)

    with :ok <- Tracker.add_label(identifier, model_label(fallback_backend)),
         :ok <- Tracker.add_label(identifier, marker_label) do
      relabeled =
        issue
        |> RemoteControlMode.add_issue_label(model_label(fallback_backend))
        |> RemoteControlMode.add_issue_label(marker_label)

      Logger.warning("Codex usage-limit fallback engaged; re-dispatching on #{fallback_backend}: #{log_context(running_entry, issue)}")

      redispatch(state, running_entry, relabeled)
    else
      {:error, reason} ->
        # Best-effort rollback: without this, a transient failure on the
        # second add leaves the model: label present with no marker, which
        # makes fallback_engaged?/1 miss it and usage_limited_on_primary?/3
        # refuse to retry (an explicit override is now present) — stranding
        # the agent paused forever with no path back.
        Tracker.remove_label(identifier, model_label(fallback_backend))

        Logger.error("Rate-limit fallback engage failed: #{log_context(running_entry, issue)} reason=#{inspect(reason)}")

        state
    end
  end

  defp apply_decision(state, running_entry, issue, :revert, opts) do
    # Read the backend actually named on the issue's own override label
    # rather than the live config value, so a config edit made while the
    # fallback was engaged can't leave a stale `model:<backend>` label
    # behind. Safe because engage never proceeds when another override
    # label already exists, so this is always our own fallback label.
    fallback_backend =
      CodingAgent.override_backend(issue) ||
        Keyword.get_lazy(opts, :fallback_backend, &Config.rate_limit_fallback_backend/0)

    marker_label = Keyword.get_lazy(opts, :marker_label, &marker_label/0)
    identifier = Map.get(running_entry, :identifier)

    with :ok <- Tracker.remove_label(identifier, marker_label),
         :ok <- Tracker.remove_label(identifier, model_label(fallback_backend)) do
      relabeled =
        issue
        |> RemoteControlMode.remove_issue_label(marker_label)
        |> RemoteControlMode.remove_issue_label(model_label(fallback_backend))

      Logger.info("Codex recovered; reverting usage-limit fallback: #{log_context(running_entry, issue)}")

      redispatch(state, running_entry, relabeled)
    else
      {:error, reason} ->
        # Best-effort rollback: re-add the marker so a transient failure on
        # the model: label removal doesn't leave the issue stranded engaged
        # forever (fallback_engaged?/1 would go false while the model:
        # label stays present, and usage_limited_on_primary?/3 refuses to
        # re-engage since an override label is still there).
        Tracker.add_label(identifier, marker_label)

        Logger.error("Rate-limit fallback revert failed: #{log_context(running_entry, issue)} reason=#{inspect(reason)}")

        state
    end
  end

  # Preserves the running entry's original worker host so the re-dispatched
  # agent lands on the same machine as its workspace — required for
  # `teardown_for_redispatch/2`'s "reused so the re-dispatched agent resumes
  # the transcript by cwd" guarantee (and this module's own on-disk-rollout
  # resume claim) to actually hold on a multi-worker deployment.
  defp redispatch(state, running_entry, relabeled_issue) do
    worker_host = Map.get(running_entry, :worker_host)

    state
    |> RemoteControlMode.teardown_for_redispatch(running_entry, :rate_limit_fallback)
    |> Dispatcher.do_dispatch_issue(relabeled_issue, nil, worker_host)
  end

  defp model_label(backend), do: "model:#{backend}"

  defp marker_label, do: "#{Config.settings!().tracker.github.label_prefix}:#{@marker_label_suffix}"

  defp log_context(running_entry, issue),
    do: "#{State.issue_context(issue)} session_id=#{State.running_entry_session_id(running_entry)}"
end
