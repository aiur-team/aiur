defmodule Aiur.Orchestrator.RateLimitFallback do
  @moduledoc """
  Automatically reroutes a running codex agent to headless Claude after
  `usage_limit_exhausted`, then reverts once `Aiur.ModelAvailability` reports
  codex available. Configured by `agent.rate_limit_fallback` (default
  `"claude"`).

  A durable `model:claude` label drives existing backend routing, while a
  second marker records Aiur's ownership so operator-authored overrides remain
  untouched. Headless Claude does not replace codex's resumable session handle,
  and redispatch preserves worker affinity, allowing the original rollout to
  resume after recovery or an Aiur restart.

  All functions execute inside the orchestrator GenServer process, called
  once per poll tick from `Reconciler.reconcile_running_lifecycle/1`.
  """

  require Logger

  alias Aiur.{CodingAgent, Config, Issue, ModelAvailability, Tracker}
  alias Aiur.Orchestrator.{Dispatcher, RemoteControlMode, State}

  @primary_backend "codex"
  @marker_label_suffix "rate-limit-fallback"

  @spec reconcile(State.t()) :: State.t()
  def reconcile(%State{} = state), do: reconcile(state, [])

  @doc false
  @spec reconcile(State.t(), keyword()) :: State.t()
  def reconcile(%State{} = state, opts) when is_list(opts) do
    # Resolve config and the availability ledger once for the whole tick.
    opts =
      opts
      |> Keyword.put_new_lazy(:fallback_backend, &Config.rate_limit_fallback_backend/0)
      |> Keyword.put_new_lazy(:marker_label, &marker_label/0)
      |> Keyword.put_new_lazy(:state, &ModelAvailability.load/0)

    Enum.reduce(state.running, state, fn {_issue_id, entry}, acc ->
      case entry do
        %{issue: %Issue{} = issue} = running_entry ->
          apply_decision(acc, running_entry, issue, decide(running_entry, issue, opts), opts)

        _ ->
          acc
      end
    end)
  end

  # Runtime dependencies in `opts` keep the decision pure in tests.
  @doc false
  @spec decide(map(), Issue.t(), keyword()) :: :engage | :revert | :noop
  def decide(running_entry, %Issue{} = issue, opts \\ []) do
    marker_label = Keyword.get_lazy(opts, :marker_label, &marker_label/0)

    cond do
      fallback_engaged?(issue, marker_label) ->
        cond do
          revert_ready?(running_entry) and ModelAvailability.available?(@primary_backend, opts) ->
            :revert

          is_nil(CodingAgent.override_backend(issue)) and usage_limited_on_primary?(running_entry, issue, opts) ->
            :engage

          true ->
            :noop
        end

      usage_limited_on_primary?(running_entry, issue, opts) ->
        :engage

      true ->
        :noop
    end
  end

  @doc false
  @spec fallback_engaged?(Issue.t(), String.t()) :: boolean()
  def fallback_engaged?(%Issue{} = issue, marker_label \\ marker_label()) do
    normalized_marker = normalize_label(marker_label)
    Enum.any?(Issue.label_names(issue), &(normalize_label(&1) == normalized_marker))
  end

  defp usage_limited_on_primary?(running_entry, issue, opts) do
    fallback_backend = Keyword.get_lazy(opts, :fallback_backend, &Config.rate_limit_fallback_backend/0)
    current_backend = Keyword.get_lazy(opts, :current_backend, fn -> CodingAgent.backend_for(issue) end)

    State.paused_running_entry?(running_entry) and
      Map.get(running_entry, :paused_reason) == :usage_limit_exhausted and
      is_binary(fallback_backend) and
      is_nil(CodingAgent.override_backend(issue)) and
      current_backend == @primary_backend
  end

  # Never tear down an agent held by an unrelated pause reason.
  defp revert_ready?(running_entry) do
    not State.paused_running_entry?(running_entry) or
      Map.get(running_entry, :paused_reason) == :usage_limit_exhausted
  end

  defp apply_decision(state, _running_entry, _issue, :noop, _opts), do: state

  defp apply_decision(state, running_entry, issue, :engage, opts) do
    fallback_backend = Keyword.get_lazy(opts, :fallback_backend, &Config.rate_limit_fallback_backend/0)
    marker_label = Keyword.get_lazy(opts, :marker_label, &marker_label/0)
    identifier = Map.get(running_entry, :identifier)
    add_label = Keyword.get(opts, :add_label_fun, &Tracker.add_label/2)
    remove_label = Keyword.get(opts, :remove_label_fun, &Tracker.remove_label/2)

    with :ok <- add_label.(identifier, marker_label),
         :ok <- add_label.(identifier, model_label(fallback_backend)) do
      relabeled =
        issue
        |> clear_selected_backend()
        |> RemoteControlMode.add_issue_label(model_label(fallback_backend))
        |> RemoteControlMode.add_issue_label(marker_label)

      Logger.warning("Codex usage-limit fallback engaged; re-dispatching on #{fallback_backend}: #{log_context(running_entry, issue)}")

      redispatch(state, running_entry, relabeled, opts)
    else
      {:error, reason} ->
        # The inert ownership marker is written before the routing override,
        # so a partial failure cannot silently redirect an operator's issue.
        rollback = remove_label.(identifier, marker_label)

        Logger.error(
          "Rate-limit fallback engage failed: #{log_context(running_entry, issue)} " <>
            "reason=#{inspect(reason)} rollback=#{inspect(rollback)}"
        )

        state
    end
  end

  defp apply_decision(state, running_entry, issue, :revert, opts) do
    # Prefer the durable override so config edits cannot leave a stale label.
    fallback_backend =
      CodingAgent.override_backend(issue) ||
        Keyword.get_lazy(opts, :fallback_backend, &Config.rate_limit_fallback_backend/0)

    marker_label = Keyword.get_lazy(opts, :marker_label, &marker_label/0)
    identifier = Map.get(running_entry, :identifier)
    add_label = Keyword.get(opts, :add_label_fun, &Tracker.add_label/2)
    remove_label = Keyword.get(opts, :remove_label_fun, &Tracker.remove_label/2)

    with :ok <- remove_label.(identifier, model_label(fallback_backend)),
         :ok <- remove_label.(identifier, marker_label) do
      relabeled =
        issue
        |> clear_selected_backend()
        |> RemoteControlMode.remove_issue_label(marker_label)
        |> RemoteControlMode.remove_issue_label(model_label(fallback_backend))

      Logger.info("Codex recovered; reverting usage-limit fallback: #{log_context(running_entry, issue)}")

      redispatch(state, running_entry, relabeled, opts)
    else
      {:error, reason} ->
        # Remove routing first and restore it if marker cleanup fails. A
        # partial failure therefore leaves either the full fallback pair or
        # only an inert marker, never an unowned model override.
        rollback = add_label.(identifier, model_label(fallback_backend))

        Logger.error(
          "Rate-limit fallback revert failed: #{log_context(running_entry, issue)} " <>
            "reason=#{inspect(reason)} rollback=#{inspect(rollback)}"
        )

        state
    end
  end

  # Keep the issue on the worker that owns its workspace and session rollout.
  defp redispatch(state, running_entry, relabeled_issue, opts) do
    worker_host = Map.get(running_entry, :worker_host)
    teardown = Keyword.get(opts, :teardown_fun, &RemoteControlMode.teardown_for_redispatch/3)
    dispatch = Keyword.get(opts, :dispatch_fun, &Dispatcher.do_dispatch_issue/4)

    state = teardown.(state, running_entry, :rate_limit_fallback)
    dispatch.(state, relabeled_issue, nil, worker_host)
  end

  defp model_label(backend), do: "model:#{backend}"

  defp normalize_label(label) when is_binary(label), do: label |> String.trim() |> String.downcase()

  defp clear_selected_backend(issue), do: %{issue | selected_backend: nil}

  defp marker_label, do: "#{Config.settings!().tracker.github.label_prefix}:#{@marker_label_suffix}"

  defp log_context(running_entry, issue),
    do: "#{State.issue_context(issue)} session_id=#{State.running_entry_session_id(running_entry)}"
end
