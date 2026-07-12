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
  the original codex rollout for free.

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
    Enum.reduce(state.running, state, fn {_issue_id, entry}, acc ->
      case entry do
        %{issue: %Issue{} = issue} = running_entry ->
          apply_decision(acc, running_entry, issue, decide(running_entry, issue, []))

        _ ->
          acc
      end
    end)
  end

  # `opts` is forwarded to `ModelAvailability.available?/2` (accepts `:state`
  # / `:path` / `:now`) and read for `:fallback_backend` — same
  # inject-for-tests-default-to-live-config shape as
  # `CodingAgent.select_for_dispatch/2`, so this decision is unit-testable
  # without a real config file or `model-usage.json` on disk.
  @doc false
  @spec decide(map(), Issue.t(), keyword()) :: :engage | :revert | :noop
  def decide(running_entry, %Issue{} = issue, opts \\ []) do
    fallback_backend = Keyword.get_lazy(opts, :fallback_backend, &Config.rate_limit_fallback_backend/0)

    cond do
      fallback_engaged?(issue) ->
        if ModelAvailability.available?(@primary_backend, opts), do: :revert, else: :noop

      usage_limited_on_primary?(running_entry, issue, fallback_backend) ->
        :engage

      true ->
        :noop
    end
  end

  @doc false
  @spec fallback_engaged?(Issue.t()) :: boolean()
  def fallback_engaged?(%Issue{} = issue), do: marker_label() in Issue.label_names(issue)

  defp usage_limited_on_primary?(running_entry, issue, fallback_backend) do
    State.paused_running_entry?(running_entry) and
      Map.get(running_entry, :paused_reason) == :usage_limit_exhausted and
      is_binary(fallback_backend) and
      CodingAgent.backend_for(issue) == @primary_backend
  end

  defp apply_decision(state, _running_entry, _issue, :noop), do: state

  defp apply_decision(state, running_entry, issue, :engage) do
    fallback_backend = Config.rate_limit_fallback_backend()
    identifier = Map.get(running_entry, :identifier)

    with :ok <- Tracker.add_label(identifier, model_label(fallback_backend)),
         :ok <- Tracker.add_label(identifier, marker_label()) do
      relabeled =
        issue
        |> RemoteControlMode.add_issue_label(model_label(fallback_backend))
        |> RemoteControlMode.add_issue_label(marker_label())

      Logger.warning("Codex usage-limit fallback engaged; re-dispatching on #{fallback_backend}: #{log_context(running_entry)}")

      redispatch(state, running_entry, relabeled)
    else
      {:error, reason} ->
        Logger.error("Rate-limit fallback engage failed: #{log_context(running_entry)} reason=#{inspect(reason)}")

        state
    end
  end

  defp apply_decision(state, running_entry, issue, :revert) do
    # Read the backend actually named on the issue's own override label
    # rather than the live config value, so a config edit made while the
    # fallback was engaged can't leave a stale `model:<backend>` label behind.
    fallback_backend = CodingAgent.override_backend(issue) || Config.rate_limit_fallback_backend()
    identifier = Map.get(running_entry, :identifier)

    with :ok <- Tracker.remove_label(identifier, marker_label()),
         :ok <- Tracker.remove_label(identifier, model_label(fallback_backend)) do
      relabeled =
        issue
        |> RemoteControlMode.remove_issue_label(marker_label())
        |> RemoteControlMode.remove_issue_label(model_label(fallback_backend))

      Logger.info("Codex recovered; reverting usage-limit fallback: #{log_context(running_entry)}")

      redispatch(state, running_entry, relabeled)
    else
      {:error, reason} ->
        Logger.error("Rate-limit fallback revert failed: #{log_context(running_entry)} reason=#{inspect(reason)}")

        state
    end
  end

  defp redispatch(state, running_entry, relabeled_issue) do
    state
    |> RemoteControlMode.teardown_for_redispatch(running_entry)
    |> Dispatcher.do_dispatch_issue(relabeled_issue, nil, nil)
  end

  defp model_label(backend), do: "model:#{backend}"

  defp marker_label, do: "#{Config.settings!().tracker.github.label_prefix}:#{@marker_label_suffix}"

  defp log_context(running_entry) do
    issue_id = get_in(running_entry, [:issue, Access.key(:id)])
    "issue_id=#{issue_id} issue_identifier=#{Map.get(running_entry, :identifier)}"
  end
end
