defmodule Aiur.Orchestrator.TokenAccounting do
  @moduledoc """
  Integrates Codex updates and maintains monotonic token and rate-limit accounting.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.Orchestrator.TokenAccounting.Payloads

  @empty_agent_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  @spec handle_codex_worker_update(State.t(), String.t(), map()) ::
          {:noreply, State.t()}
  def handle_codex_worker_update(
        %State{running: running} = state,
        issue_id,
        %{event: _, timestamp: _} = update
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_agent_token_delta(token_delta)
          |> apply_agent_rate_limits(update)

        StatusReport.notify_dashboard(state)
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  @spec integrate_codex_update(map(), %{event: term(), timestamp: DateTime.t()}) :: {map(), map()}
  def integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    agent_input_tokens = Map.get(running_entry, :agent_input_tokens, 0)
    agent_output_tokens = Map.get(running_entry, :agent_output_tokens, 0)
    agent_total_tokens = Map.get(running_entry, :agent_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :agent_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :agent_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :agent_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        agent_input_tokens: agent_input_tokens + token_delta.input_tokens,
        agent_output_tokens: agent_output_tokens + token_delta.output_tokens,
        agent_total_tokens: agent_total_tokens + token_delta.total_tokens,
        agent_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        agent_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        agent_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  @spec record_session_completion_totals(State.t(), map()) :: State.t()
  def record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = State.running_seconds(running_entry.started_at, DateTime.utc_now())

    agent_totals =
      apply_token_delta(
        state.agent_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | agent_totals: agent_totals}
  end

  def record_session_completion_totals(state, _running_entry), do: state

  @spec apply_agent_token_delta(State.t(), map()) :: State.t()
  def apply_agent_token_delta(
        %{agent_totals: agent_totals} = state,
        %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
      )
      when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | agent_totals: apply_token_delta(agent_totals, token_delta)}
  end

  def apply_agent_token_delta(state, _token_delta), do: state

  @spec apply_agent_rate_limits(State.t(), map()) :: State.t()
  def apply_agent_rate_limits(%State{} = state, update) when is_map(update) do
    case Payloads.extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | agent_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  def apply_agent_rate_limits(state, _update), do: state

  defp apply_token_delta(nil, token_delta),
    do: apply_token_delta(@empty_agent_totals, token_delta)

  defp apply_token_delta(agent_totals, token_delta) do
    input_tokens = Map.get(agent_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(agent_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(agent_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(agent_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = Payloads.extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :agent_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :agent_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :agent_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = Payloads.get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end
end
