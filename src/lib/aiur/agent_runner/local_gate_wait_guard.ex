defmodule Aiur.AgentRunner.LocalGateWaitGuard do
  @moduledoc false

  alias Aiur.AgentRunner.LocalGateCICache

  @type state :: %{started_at_ms: integer() | nil, steered?: boolean()}

  @doc false
  @spec new_state() :: state()
  def new_state, do: %{started_at_ms: nil, steered?: false}

  @doc false
  @spec started(state(), String.t(), integer()) :: state()
  def started(state, command, now_ms) do
    case activity(command, state.started_at_ms != nil) do
      :gate -> %{state | started_at_ms: state.started_at_ms || now_ms}
      :wait -> state
      :other -> new_state()
    end
  end

  @doc false
  @spec completed(state(), String.t(), integer(), keyword()) ::
          {state(), :ok | {:steer, String.t()} | {:stop, map(), non_neg_integer()}}
  def completed(state, command, now_ms, opts) do
    state = started(state, command, now_ms)

    elapsed_ms =
      if is_integer(state.started_at_ms), do: max(now_ms - state.started_at_ms, 0), else: 0

    evaluate(state, elapsed_ms, now_ms, opts)
  end

  defp evaluate(%{started_at_ms: started_at_ms} = state, elapsed_ms, now_ms, opts)
       when is_integer(started_at_ms) do
    steer_ms = Keyword.get(opts, :steer_after_ms, 20 * 60_000)
    stop_ms = Keyword.get(opts, :stop_after_ms, 30 * 60_000)
    max_ci_age_ms = Keyword.get(opts, :max_ci_age_ms, 15 * 60_000)

    if elapsed_ms >= steer_ms do
      verdict = read_ci(opts)

      if LocalGateCICache.green_current?(verdict, now_ms, max_ci_age_ms) do
        green_action(state, verdict, elapsed_ms, stop_ms)
      else
        {state, :ok}
      end
    else
      {state, :ok}
    end
  end

  defp evaluate(state, _elapsed_ms, _now_ms, _opts), do: {state, :ok}

  defp green_action(%{steered?: false} = state, verdict, elapsed_ms, _stop_ms) do
    head = verdict.head_sha
    minutes = div(elapsed_ms, 60_000)

    message =
      "Required CI is green at #{head}. Stop the local test or gate, refresh the PR body, and mark the PR ready for review."

    {%{state | steered?: true}, {:steer, message <> " (local gate wait: #{minutes} minutes)"}}
  end

  defp green_action(state, verdict, elapsed_ms, stop_ms) when elapsed_ms >= stop_ms,
    do: {state, {:stop, verdict, div(elapsed_ms, 60_000)}}

  defp green_action(state, _verdict, _elapsed_ms, _stop_ms), do: {state, :ok}

  defp read_ci(opts) do
    case Keyword.get(opts, :ci_reader) do
      reader when is_function(reader, 0) -> reader.()
      _missing -> :unavailable
    end
  rescue
    _error -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  defp activity(command, active?) do
    normalized = String.downcase(command)

    cond do
      local_gate_command?(normalized) -> :gate
      active? and Regex.match?(~r/(?:^|\s)(?:sleep|usleep)(?:\s|$)/, normalized) -> :wait
      active? and read_only_ci_command?(normalized) -> :wait
      gate_log_poll?(normalized) -> :gate
      true -> :other
    end
  end

  defp read_only_ci_command?(command) do
    Regex.match?(~r{(?:^|\s)gh\s+(?:pr\s+(?:checks|view)|run\s+view)(?:\s|$)}, command)
  end

  defp local_gate_command?(command) do
    Regex.match?(
      ~r{(?:^|\s)(?:(?:[.\w/-]+/)?aiur(?:dev)?\s+pre-pr|mix\s+(?:test|aiur\.affected_tests)|make\s+(?:ci|coverage-partition)|(?:run-pre-handoff-code-checks|pre-handoff-guards))(?:\s|$)},
      command
    )
  end

  defp gate_log_poll?(command) do
    polling? = Regex.match?(~r/(?:^|\s)(?:tail|grep|cat|head|less|watch)(?:\s|$)/, command)

    gate_path? =
      Regex.match?(
        ~r/(?:pre-pr|pre-handoff|coverage|mix\.log|test\.log|gate[-_.])/,
        command
      )

    polling? and gate_path?
  end
end
