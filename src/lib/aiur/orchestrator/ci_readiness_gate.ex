defmodule Aiur.Orchestrator.CiReadinessGate do
  @moduledoc """
  Advisory CI readiness checks for dispatch.
  """

  alias Aiur.Alerts
  alias Aiur.CodeHost
  alias Aiur.CodeHost.CiReadiness
  alias Aiur.Config
  alias Aiur.Orchestrator.State

  @ci_readiness_timeout_ms 5_000
  @ci_readiness_retry_ms 60_000
  # Readiness is advisory at dispatch: the operator may be deliberately
  # setting up a repository mid-run, so this must never hold otherwise-valid
  # tickets. A transient inspection failure retries on subsequent polls, but
  # only emits its needs-attention alert once.
  @doc false
  @spec maybe_warn_ci_readiness(State.t()) :: State.t()
  def maybe_warn_ci_readiness(state) do
    state = reset_ci_readiness_for_config_change(state)
    do_maybe_warn_ci_readiness(state)
  end

  defp do_maybe_warn_ci_readiness(%State{ci_readiness_checked: true} = state) do
    if CodeHost.ci_readiness() do
      reconcile_completed_ci_readiness(state)
    else
      state
    end
  end

  defp do_maybe_warn_ci_readiness(%State{ci_readiness_retry_at_ms: retry_at_ms} = state) when is_integer(retry_at_ms) do
    if retry_at_ms > System.monotonic_time(:millisecond) do
      state
    else
      start_initial_ci_readiness_check(state, Config.tracker_kind(), Config.base_branch(), check_fun())
    end
  end

  defp do_maybe_warn_ci_readiness(%State{initial_dispatch_cycle: true} = state) do
    start_initial_ci_readiness_check(state, Config.tracker_kind(), Config.base_branch(), check_fun())
  end

  defp do_maybe_warn_ci_readiness(state), do: state

  defp check_fun do
    if provider = CodeHost.ci_readiness(), do: provider.check_fun()
  end

  defp reset_ci_readiness_for_config_change(state) do
    provider = CodeHost.ci_readiness()
    scope = if provider, do: provider.readiness_scope(base_branch: Config.base_branch()), else: {:no_ci_readiness, Config.tracker_kind()}

    if state.ci_readiness_scope == scope do
      state
    else
      if is_pid(state.ci_readiness_check_pid) and Process.alive?(state.ci_readiness_check_pid) do
        Process.exit(state.ci_readiness_check_pid, :kill)
      end

      %{
        state
        | ci_readiness_checked: false,
          ci_readiness_unavailable_alerted: false,
          ci_readiness_check_pid: nil,
          ci_readiness_check_token: nil,
          ci_readiness_check_provider: nil,
          ci_readiness_retry_at_ms: System.monotonic_time(:millisecond),
          ci_readiness_scope: scope,
          ci_readiness_result: nil
      }
    end
  end

  defp reconcile_completed_ci_readiness(state) do
    provider = CodeHost.ci_readiness()

    case provider.cached_result(base_branch: Config.base_branch()) do
      :unavailable ->
        state = %{state | ci_readiness_checked: false, ci_readiness_result: nil}
        start_initial_ci_readiness_check(state, Config.tracker_kind(), Config.base_branch(), check_fun())

      result when result == state.ci_readiness_result ->
        state

      result ->
        accept_cached_ci_readiness_result(state, result, &Alerts.emit_system/2)
    end
  end

  @doc false
  @spec start_initial_ci_readiness_check(State.t(), String.t() | nil, String.t(), function()) :: State.t()
  def start_initial_ci_readiness_check(%State{ci_readiness_checked: true} = state, _kind, _base_branch, _check_fun), do: state

  def start_initial_ci_readiness_check(%State{ci_readiness_check_pid: pid} = state, _kind, _base_branch, _check_fun) when is_pid(pid),
    do: state

  def start_initial_ci_readiness_check(state, kind, base_branch, check_fun) do
    if provider = CodeHost.ci_readiness(kind) do
      start_check(state, base_branch, check_fun, provider)
    else
      %{state | ci_readiness_checked: true}
    end
  end

  defp start_check(state, base_branch, check_fun, provider) do
    parent = self()
    token = make_ref()

    case Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
           send(parent, {:ci_readiness_result, token, check_fun.(base_branch: base_branch, timeout_ms: @ci_readiness_timeout_ms)})
         end) do
      {:ok, pid} ->
        Process.send_after(parent, {:ci_readiness_timeout, token}, @ci_readiness_timeout_ms)
        %{state | ci_readiness_check_pid: pid, ci_readiness_check_token: token, ci_readiness_check_provider: provider, ci_readiness_retry_at_ms: nil}

      {:error, reason} ->
        record_ci_readiness_result(state, {:error, reason}, &Alerts.emit_system/2, provider)
    end
  end

  @doc false
  @spec handle_ci_readiness_result(State.t(), reference(), {:ok, CiReadiness.result()} | {:error, term()}) :: State.t()
  def handle_ci_readiness_result(%State{ci_readiness_check_token: token} = state, token, result) do
    provider = state.ci_readiness_check_provider

    state
    |> clear_ci_readiness_check()
    |> record_ci_readiness_result(result, &Alerts.emit_system/2, provider)
  end

  def handle_ci_readiness_result(state, _token, _result), do: state

  @doc false
  @spec handle_ci_readiness_timeout(State.t(), reference()) :: State.t()
  def handle_ci_readiness_timeout(%State{ci_readiness_check_token: token, ci_readiness_check_pid: pid} = state, token) do
    if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :kill)

    provider = state.ci_readiness_check_provider

    state
    |> clear_ci_readiness_check()
    |> record_ci_readiness_result({:error, :timeout}, &Alerts.emit_system/2, provider)
  end

  def handle_ci_readiness_timeout(state, _token), do: state

  defp clear_ci_readiness_check(state), do: %{state | ci_readiness_check_pid: nil, ci_readiness_check_token: nil, ci_readiness_check_provider: nil}

  @doc false
  @spec check_initial_ci_readiness(State.t(), String.t() | nil, String.t(), function(), function()) :: State.t()
  def check_initial_ci_readiness(%State{ci_readiness_checked: true} = state, _kind, _base_branch, _check_fun, _emit_fun), do: state

  def check_initial_ci_readiness(state, kind, base_branch, check_fun, emit_fun) do
    if provider = CodeHost.ci_readiness(kind) do
      record_ci_readiness_result(state, check_fun.(base_branch: base_branch), emit_fun, provider)
    else
      %{state | ci_readiness_checked: true}
    end
  end

  defp record_ci_readiness_result(state, _result, _emit_fun, nil), do: %{state | ci_readiness_checked: true}

  defp record_ci_readiness_result(state, {:ok, %{ready?: true} = readiness}, _emit_fun, provider) do
    provider.cache_result(readiness)
    %{state | ci_readiness_checked: true, ci_readiness_retry_at_ms: nil, ci_readiness_result: readiness}
  end

  defp record_ci_readiness_result(state, {:ok, readiness}, emit_fun, provider) do
    provider.cache_result(readiness)

    emit_fun.("system.ci_readiness.not_ready",
      message: "Repository CI readiness is incomplete",
      reason: provider.format(readiness),
      needs_attention: true,
      severity: "warning"
    )

    %{state | ci_readiness_checked: true, ci_readiness_retry_at_ms: nil, ci_readiness_result: readiness}
  end

  defp record_ci_readiness_result(state, {:error, reason}, emit_fun, provider) do
    if retryable_ci_readiness_error?(reason, provider) do
      maybe_emit_ci_readiness_unavailable(state, reason, emit_fun, provider)

      %{
        state
        | ci_readiness_unavailable_alerted: true,
          ci_readiness_retry_at_ms: System.monotonic_time(:millisecond) + ci_readiness_retry_delay_ms(reason),
          ci_readiness_result: nil
      }
    else
      readiness = provider.unavailable(Config.base_branch(), reason)
      provider.cache_result(readiness)
      maybe_emit_ci_readiness_unavailable(state, reason, emit_fun, provider)
      %{state | ci_readiness_checked: true, ci_readiness_retry_at_ms: nil, ci_readiness_result: readiness}
    end
  end

  defp accept_cached_ci_readiness_result(state, %{ready?: true} = readiness, _emit_fun) do
    %{state | ci_readiness_checked: true, ci_readiness_retry_at_ms: nil, ci_readiness_result: readiness}
  end

  defp accept_cached_ci_readiness_result(state, readiness, emit_fun) do
    emit_fun.("system.ci_readiness.not_ready",
      message: "Repository CI readiness is incomplete",
      reason: CodeHost.ci_readiness().format(readiness),
      needs_attention: true,
      severity: "warning"
    )

    %{state | ci_readiness_checked: true, ci_readiness_retry_at_ms: nil, ci_readiness_result: readiness}
  end

  defp retryable_ci_readiness_error?(:timeout, _provider), do: true

  defp retryable_ci_readiness_error?(reason, provider), do: provider.retryable_error?(reason)

  defp ci_readiness_retry_delay_ms({:github, :rate_limited, detail}) when is_map(detail) do
    case Map.get(detail, :retry_after) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds * 1_000
      _ -> retry_delay_from_reset(Map.get(detail, :reset_at)) || @ci_readiness_retry_ms
    end
  end

  defp ci_readiness_retry_delay_ms(_reason), do: @ci_readiness_retry_ms

  defp retry_delay_from_reset(reset_at) when is_binary(reset_at) do
    case DateTime.from_iso8601(reset_at) do
      {:ok, reset_at, _offset} -> max(DateTime.diff(reset_at, DateTime.utc_now(), :millisecond), 0)
      _ -> nil
    end
  end

  defp retry_delay_from_reset(_reset_at), do: nil

  defp maybe_emit_ci_readiness_unavailable(%State{ci_readiness_unavailable_alerted: true}, _reason, _emit_fun, _provider), do: :ok

  defp maybe_emit_ci_readiness_unavailable(_state, reason, emit_fun, provider) do
    emit_fun.("system.ci_readiness.unavailable",
      message: "Repository CI readiness could not be inspected",
      reason: provider.error_message(reason),
      needs_attention: true,
      severity: "warning"
    )
  end
end
