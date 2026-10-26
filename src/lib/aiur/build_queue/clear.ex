defmodule Aiur.BuildQueue.Clear do
  @moduledoc false
  alias Aiur.BuildQueue.{Events, ListCommands, Reconcile}

  @empty %{queues: [], items: [], edges: [], intents: [], latches: []}

  @spec prepare(map(), keyword()) :: {:ok, map(), list(), map()} | {:error, term()}
  def prepare(state, opts) do
    with :ok <- confirm(opts),
         {:fresh, observations} <- Reconcile.snapshot(state) do
      marker = "#{state.settings.tracker.github.label_prefix}:queued"
      member_ids = for item <- state.document.items, not Map.has_key?(observations, item.issue_id), do: item.issue_id
      marked_ids = for {id, row} <- observations, marker in row.labels, do: id
      actions = Enum.map(Enum.uniq(member_ids ++ marked_ids) |> Enum.sort(), &{:unmark, &1})
      document = ListCommands.record(state, @empty, actions, observations)
      {:ok, document, actions, observations}
    else
      {:unknown, _} -> {:error, :observation_unavailable}
      error -> error
    end
  end

  defp confirm(opts) do
    cond do
      opts[:remove_markers] != true -> {:error, :invalid_arguments}
      opts[:yes] != true -> {:error, :confirmation_required}
      true -> :ok
    end
  end

  @spec finish(map()) :: map()
  def finish(%{document: %{queues: [], items: [], intents: [_ | _]}} = state) do
    if Enum.all?(state.document.intents, &(&1.action == :unmark)) and ListCommands.pending(state.document) == [] do
      case state.store.save(@empty) do
        :ok ->
          Events.saved(state.document, @empty)
          %{state | document: @empty}

        {:error, _} ->
          %{state | status: :store_unavailable}
      end
    else
      state
    end
  end

  def finish(state), do: state
end
