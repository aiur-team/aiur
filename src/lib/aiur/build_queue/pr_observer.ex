defmodule Aiur.BuildQueue.PRObserver do
  @moduledoc false
  alias Aiur.Events.Publisher
  require Logger

  @spec observe(map(), map()) :: {map(), map()}
  def observe(observations, state) do
    tracker = state.tracker

    if Code.ensure_loaded?(tracker) and function_exported?(tracker, :ticket_pull_request, 1) do
      ids = state.document.edges |> Enum.map(& &1.prerequisite) |> Enum.uniq()
      Enum.reduce(ids, {observations, state}, &observe_ticket/2)
    else
      {observations, state}
    end
  end

  defp observe_ticket(id, {observations, state}) do
    observation = observations[id]
    error = "#{state.settings.tracker.github.label_prefix}:error"

    if observation && observation.open? == true && error not in observation.labels do
      case state.tracker.ticket_pull_request(id) do
        {:ok, %{state: :closed, merged?: false} = pr} ->
          {Map.put(observations, id, %{observation | pr: :closed_unmerged}), publish(id, pr, state)}

        {:ok, %{merged?: merged, state: status}} ->
          {Map.put(observations, id, %{observation | pr: if(merged, do: :merged, else: status)}), state}

        {:ok, nil} ->
          {observations, state}

        {:error, reason} ->
          Logger.warning("Build queue PR observation failed for #{id}: #{inspect(reason)}")
          {observations, state}
      end
    else
      {observations, state}
    end
  end

  defp publish(id, %{number: number, version: version}, state) do
    previous = Map.get(state, :published_pr_versions, %{})
    identity = {number, version}

    if previous[id] == identity do
      state
    else
      payload = %{class: :live, refs: %{ticket: id, pr_number: number}, pr_number: number}

      case publish_event(id, payload) do
        {:ok, _, _} ->
          Map.put(state, :published_pr_versions, Map.put(previous, id, identity))

        outcome ->
          Logger.warning("Build queue closed-unmerged event for #{id} was not published: #{inspect(outcome)}")
          state
      end
    end
  end

  defp publish(_id, _pr, state), do: state

  defp publish_event(id, payload) do
    Publisher.publish("ticket.#{id}.pr.closed_unmerged", payload)
  rescue
    error -> {:error, {:publication_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:publication_unavailable, reason}}
  end
end
