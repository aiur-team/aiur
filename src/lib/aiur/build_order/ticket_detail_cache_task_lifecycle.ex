defmodule Aiur.BuildOrder.TicketDetailCache.TaskLifecycle do
  @moduledoc false

  alias Aiur.BuildOrder.TicketDetail
  alias Aiur.BuildOrder.TicketDetail.{Failure, Snapshot}
  alias Aiur.BuildOrder.TicketDetail.Repository
  alias Aiur.BuildOrder.TicketDetailCache.Policy

  @spec start_refresh(Policy.entry(), map(), Aiur.TrackerIdentity.repository()) :: {Policy.entry(), map(), list()}
  def start_refresh(entry, state, repository) do
    generation = state.next_generation
    now = now(state)

    case start_task(state, entry.identity, repository) do
      {:ok, task} ->
        timeout_ref =
          Process.send_after(
            self(),
            {:refresh_timeout, task.ref, generation},
            state.refresh_timeout_ms
          )

        entry = %{
          entry
          | generation: generation,
            last_attempt_at: now,
            inflight: %{
              generation: generation,
              pid: task.pid,
              ref: task.ref,
              repository: repository,
              timeout_ref: timeout_ref
            }
        }

        state =
          %{
            state
            | next_generation: generation + 1,
              entries: Map.put(state.entries, Policy.cache_key(entry.identity), entry)
          }
          |> put_in([:inflight_by_ref, task.ref], Policy.cache_key(entry.identity))

        {entry, state, []}

      :error ->
        entry = %{
          entry
          | generation: generation,
            last_attempt_at: now,
            failure: %Failure{kind: :transport},
            inflight: nil
        }

        state = %{
          state
          | next_generation: generation + 1,
            entries: Map.put(state.entries, Policy.cache_key(entry.identity), entry)
        }

        {entry, state, [Policy.state_for(entry, state)]}
    end
  end

  @spec apply_completion(reference(), term(), map()) :: {map(), list()}
  def apply_completion(ref, result, state) do
    case Map.pop(state.inflight_by_ref, ref) do
      {nil, _inflight_by_ref} ->
        {state, []}

      {key, inflight_by_ref} ->
        state = %{state | inflight_by_ref: inflight_by_ref}
        apply_entry_completion(key, ref, result, state)
    end
  end

  @spec timeout_refresh(reference(), pos_integer(), map()) :: {map(), list()}
  def timeout_refresh(ref, generation, state) do
    with key when not is_nil(key) <- Map.get(state.inflight_by_ref, ref),
         %{inflight: %{ref: ^ref, generation: ^generation, pid: pid}} <- Map.get(state.entries, key) do
      terminate_task(state.task_supervisor, pid)
      Process.demonitor(ref, [:flush])
      apply_completion(ref, {:error, %Failure{kind: :timeout}}, state)
    else
      _ -> {state, []}
    end
  end

  @spec cancel_all(map()) :: map()
  def cancel_all(state) do
    state.entries
    |> Map.values()
    |> Enum.reduce(state, fn
      %{inflight: nil}, state -> state
      %{inflight: inflight}, state -> cancel_inflight(state, inflight)
    end)
    |> Map.put(:inflight_by_ref, %{})
  end

  defp apply_entry_completion(key, ref, result, state) do
    case Map.fetch(state.entries, key) do
      {:ok,
       %{
         inflight: %{
           ref: ^ref,
           generation: generation,
           repository: repository,
           timeout_ref: timeout_ref
         }
       } = entry} ->
        Process.cancel_timer(timeout_ref)

        if repository_matches_active?(repository, state.active_repository) do
          entry = complete_entry(entry, result, state, generation)
          state = %{state | entries: Map.put(state.entries, key, entry)}
          {state, [Policy.state_for(entry, state)]}
        else
          state = %{state | entries: Map.delete(state.entries, key)}
          {state, [Policy.evicted_state(entry)]}
        end

      _ ->
        {state, []}
    end
  end

  defp start_task(state, identity, repository) do
    {:ok,
     Task.Supervisor.async_nolink(state.task_supervisor, fn ->
       read(state, identity, repository)
     end)}
  catch
    :exit, _reason -> :error
    :error, _reason -> :error
  end

  defp read(%{reader: reader}, identity, _repository) when is_function(reader, 1), do: reader.(identity)

  defp read(state, identity, repository) do
    TicketDetail.fetch(identity,
      configured_repo: repository,
      max_description_bytes: state.max_description_bytes,
      now: now(state)
    )
  end

  defp cancel_inflight(state, inflight) do
    Process.cancel_timer(inflight.timeout_ref)
    Process.demonitor(inflight.ref, [:flush])
    terminate_task(state.task_supervisor, inflight.pid)
    state
  end

  defp terminate_task(task_supervisor, pid) do
    Task.Supervisor.terminate_child(task_supervisor, pid)
  catch
    :exit, _reason -> :ok
    :error, _reason -> :ok
  end

  defp repository_matches_active?({_, _} = repository, {_, _} = active_repository) do
    Repository.same_repository?(repository, active_repository)
  end

  defp repository_matches_active?(_repository, _active_repository), do: false

  defp complete_entry(%{identity: identity} = entry, {:ok, %Snapshot{identity: identity} = detail}, state, _generation) do
    %{entry | detail: detail, failure: nil, last_success_ms: now_ms(state), inflight: nil}
  end

  defp complete_entry(entry, {:ok, %Snapshot{}}, _state, _generation) do
    %{entry | failure: %Failure{kind: :provider_identity_mismatch}, inflight: nil}
  end

  defp complete_entry(entry, {:error, %Failure{} = failure}, _state, _generation), do: %{entry | failure: failure, inflight: nil}
  defp complete_entry(entry, _unexpected, _state, _generation), do: %{entry | failure: %Failure{kind: :transport}, inflight: nil}
  defp now(state), do: state.now.()
  defp now_ms(state), do: state.clock_ms.()
end
