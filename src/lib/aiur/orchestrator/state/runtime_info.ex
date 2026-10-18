defmodule Aiur.Orchestrator.State.RuntimeInfo do
  @moduledoc false
  alias Aiur.Issue
  alias Aiur.LiveConversation.Source, as: LiveConversationSource
  alias Aiur.Orchestrator.{PauseResume, State, StatusReport}
  alias Aiur.Orchestrator.State.RunningEntries

  @spec handle_worker_runtime_info(State.t(), String.t(), map()) :: {:noreply, State.t()}
  def handle_worker_runtime_info(%State{running: running} = state, issue_id, runtime_info)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
          |> maybe_put_runtime_value(:rework_head_sha, runtime_info[:rework_head_sha])
          |> maybe_put_live_conversation(runtime_info[:live_conversation])

        if updated_running_entry == running_entry do
          {:noreply, state}
        else
          next_state = %{state | running: Map.put(running, issue_id, updated_running_entry)}
          StatusReport.notify_dashboard(next_state)
          {:noreply, next_state}
        end
    end
  end

  @spec handle_live_conversation_restart(State.t(), String.t(), DateTime.t()) :: {:noreply, State.t()}
  def handle_live_conversation_restart(%State{} = state, projection_epoch, observed_at)
      when is_binary(projection_epoch) and is_struct(observed_at, DateTime) do
    running =
      Map.new(state.running, fn {issue_id, entry} ->
        generation = get_in(entry, [:control, :generation])

        status = %{
          projection_epoch: projection_epoch,
          revision: 0,
          source_revision: 0,
          generation_handle: nil,
          source: nil,
          state: :restart_unknown,
          health: :unknown,
          freshness: :unknown,
          observed_at: observed_at
        }

        fence = %{
          projection_epoch: projection_epoch,
          revision: 0,
          source_revision: 0,
          source: nil,
          worker_generation: generation,
          restart_locked?: true
        }

        {issue_id,
         entry
         |> Map.put(:live_conversation, status)
         |> Map.put(:live_conversation_fence, fence)}
      end)

    next_state = %{state | running: running}

    if next_state == state do
      {:noreply, state}
    else
      StatusReport.notify_dashboard(next_state)
      {:noreply, next_state}
    end
  end

  def handle_live_conversation_restart(%State{} = state, _projection_epoch, _observed_at),
    do: {:noreply, state}

  @spec handle_repl_session_runtime(State.t(), String.t(), map()) :: {:noreply, State.t()}
  def handle_repl_session_runtime(%State{running: running} = state, issue_id, info)
      when is_binary(issue_id) and is_map(info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:repl_pane_id, info[:pane_id])
          |> maybe_put_runtime_value(:repl_tmux_socket, info[:tmux_socket])
          |> maybe_put_runtime_value(:repl_os_pid, info[:os_pid])
          |> maybe_put_runtime_value(:headless_os_pid, info[:headless_os_pid])
          |> maybe_put_runtime_value(:headless_process_group_id, info[:headless_process_group_id])
          |> maybe_put_runtime_value(:repl_rc_session_url, info[:session_url])

        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  @spec handle_session_execution_info(State.t(), String.t(), map()) :: {:noreply, State.t()}
  def handle_session_execution_info(
        %State{running: running} = state,
        issue_id,
        %{backend: backend} = info
      )
      when is_binary(issue_id) and is_binary(backend) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        session_execution = %{
          backend: backend,
          requested_model: optional_runtime_string(info[:requested_model]),
          resolved_model: nil,
          effort: optional_runtime_string(info[:effort]),
          account: optional_runtime_string(info[:account]),
          account_selection_reason: optional_runtime_string(info[:account_selection_reason])
        }

        {:noreply, put_session_execution(state, issue_id, running_entry, session_execution)}
    end
  end

  @doc """
  Records the model a running session reported actually serving its turns.

  The route names a backend and at most a model tag; which concrete version
  answered is only knowable once the agent is running, and it arrives after
  the session's execution facts. Merge it so a late observation names the
  model on the dashboard without erasing the backend and route that were
  already reported.
  """
  @spec handle_session_resolved_model(State.t(), String.t(), String.t()) :: {:noreply, State.t()}
  def handle_session_resolved_model(%State{running: running} = state, issue_id, model)
      when is_binary(issue_id) and is_binary(model) and model != "" do
    with running_entry when is_map(running_entry) <- Map.get(running, issue_id),
         %{} = execution <- Map.get(running_entry, :session_execution),
         false <- Map.get(execution, :resolved_model) == model do
      {:noreply, put_session_execution(state, issue_id, running_entry, Map.put(execution, :resolved_model, model))}
    else
      _unchanged -> {:noreply, state}
    end
  end

  def handle_session_resolved_model(%State{} = state, _issue_id, _model), do: {:noreply, state}

  defp put_session_execution(%State{running: running} = state, issue_id, running_entry, session_execution) do
    updated_state =
      %{state | running: Map.put(running, issue_id, Map.put(running_entry, :session_execution, session_execution))}

    StatusReport.notify_dashboard(updated_state)
    updated_state
  end

  @spec note_agent_activity(State.t(), String.t()) :: State.t()
  # Claude hook activity is the liveness signal for backends without codex updates.
  def note_agent_activity(%State{} = state, identifier) when is_binary(identifier) do
    case RunningEntries.find_running_key_by_identifier(state.running, identifier) do
      nil ->
        state

      issue_id ->
        update_in(
          state.running,
          &PauseResume.reset_last_codex_timestamp(&1, issue_id, DateTime.utc_now())
        )
    end
  end

  @spec alive?(term()) :: boolean()
  defdelegate alive?(name), to: Aiur.Orchestrator.State.ProcessLiveness
  @spec maybe_put_runtime_value(term(), term(), term()) :: term()
  def maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  def maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp optional_runtime_string(value) when is_binary(value), do: value
  defp optional_runtime_string(_value), do: nil

  defp maybe_put_live_conversation(running_entry, nil), do: running_entry

  defp maybe_put_live_conversation(running_entry, status) do
    with %{} = status <- live_conversation_runtime(status),
         true <- authoritative_live_conversation_status?(running_entry, status) do
      fence = %{
        projection_epoch: status.projection_epoch,
        revision: status.revision,
        source_revision: status.source_revision,
        source: status.source,
        worker_generation: status.source.worker_generation,
        restart_locked?: false
      }

      running_entry
      |> Map.put(:live_conversation, status)
      |> Map.put(:live_conversation_fence, fence)
    else
      _invalid_or_stale -> running_entry
    end
  end

  defp live_conversation_runtime(%{} = status) do
    if valid_runtime_identity?(status) and valid_runtime_revisions?(status) and
         valid_runtime_enums?(status) and is_struct(Map.get(status, :observed_at), DateTime) do
      Map.take(status, [
        :projection_epoch,
        :revision,
        :source_revision,
        :generation_handle,
        :source,
        :state,
        :health,
        :freshness,
        :observed_at
      ])
    end
  end

  defp live_conversation_runtime(_status), do: nil

  defp valid_runtime_identity?(status) do
    valid_projection_epoch?(Map.get(status, :projection_epoch)) and
      valid_conversation_handle?(Map.get(status, :generation_handle)) and
      valid_conversation_source?(Map.get(status, :source))
  end

  defp valid_runtime_revisions?(status) do
    revision = Map.get(status, :revision)
    source_revision = Map.get(status, :source_revision)

    is_integer(revision) and revision > 0 and is_integer(source_revision) and
      source_revision > 0 and source_revision <= revision
  end

  defp valid_runtime_enums?(status) do
    Map.get(status, :state) in [:live, :ended, :known_empty, :stale, :unavailable, :restart_unknown] and
      Map.get(status, :health) in [:healthy, :unavailable, :unknown] and
      Map.get(status, :freshness) in [:current, :stale, :unknown]
  end

  defp authoritative_live_conversation_status?(running_entry, status) do
    expected_generation = get_in(running_entry, [:control, :generation])

    status.source.worker_generation == expected_generation and
      matching_live_identity?(running_entry, status.source.identity) and
      newer_live_conversation_status?(running_entry, status)
  end

  defp matching_live_identity?(running_entry, identity) do
    case Issue.tracker_identity(Map.get(running_entry, :issue)) do
      %{kind: kind, owner: owner, repository: repository, identifier: identifier} ->
        identity == %{
          version: 1,
          kind: kind,
          owner: owner,
          repository: repository,
          identifier: identifier
        }

      _missing ->
        false
    end
  end

  defp newer_live_conversation_status?(running_entry, status) do
    case Map.get(running_entry, :live_conversation_fence) do
      nil ->
        true

      %{projection_epoch: epoch} when epoch != status.projection_epoch ->
        false

      %{restart_locked?: true} ->
        status.state == :ended

      %{revision: revision} when status.revision <= revision ->
        false

      %{source: source, source_revision: source_revision} ->
        source == status.source or status.source_revision > source_revision

      _invalid_fence ->
        false
    end
  end

  defp valid_projection_epoch?("projection:" <> digest) do
    byte_size(digest) == 43 and Regex.match?(~r/^[A-Za-z0-9_-]+$/, digest)
  end

  defp valid_projection_epoch?(_epoch), do: false

  defp valid_conversation_handle?(handle), do: LiveConversationSource.valid_handle?(handle)

  defp valid_conversation_source?(%{
         identity: %{
           version: 1,
           kind: :github,
           owner: owner,
           repository: repository,
           identifier: identifier
         },
         run_id: run_id,
         attempt_id: attempt_id,
         session_id: session_id,
         backend: backend,
         worker_generation: generation
       }) do
    Enum.all?([owner, repository, identifier, run_id, attempt_id, backend], &valid_runtime_field?/1) and
      valid_runtime_session?(session_id) and is_integer(generation) and generation > 0
  end

  defp valid_conversation_source?(_source), do: false
  defp valid_runtime_session?(nil), do: true

  defp valid_runtime_session?("session:" <> digest) do
    byte_size(digest) == 43 and Regex.match?(~r/^[A-Za-z0-9_-]+$/, digest)
  end

  defp valid_runtime_session?(_session), do: false

  defp valid_runtime_field?(field), do: is_binary(field) and field != "" and byte_size(field) <= 256
end
