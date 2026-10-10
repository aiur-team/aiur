defmodule Aiur.BuildQueue.ListCommands do
  @moduledoc false
  alias Aiur.BuildQueue.{ListMutations, Model.Intent, QueueTriggers, Reconcile, Settings}

  @spec prepare(map(), tuple()) :: {:ok, map(), list(), map()} | {:error, term()}
  def prepare(state, command) do
    observations = Reconcile.observations(state)

    with {:ok, document, actions} <- edit(state.document, command, state.clock.()),
         :ok <- open_members(state, command) do
      {:ok, record(state, document, actions, observations), actions, observations}
    end
  end

  @spec queue_id(map()) :: {:ok, String.t()} | {:error, :queue_limit}
  defdelegate queue_id(document), to: ListMutations

  @spec record(map(), map(), list(), map()) :: map()
  def record(state, document, actions, observations) do
    intents = Enum.map(actions, &intent(&1, observations, state))
    %{document | intents: document.intents ++ intents}
  end

  @spec pending(map()) :: list()
  def pending(document) do
    members = MapSet.new(document.items, & &1.issue_id)

    document.intents
    |> Enum.filter(&(&1.action in [:mark, :unmark]))
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.issue_id)
    |> Enum.reverse()
    |> Enum.reject(&(&1.outcome == :ok))
    |> Enum.filter(&wanted?(&1, members))
    |> Enum.map(&{&1.action, &1.issue_id})
  end

  # Replay only what current membership still wants: a stale request recovered after a crash must not strip a member's marker.
  defp wanted?(%{action: :mark, issue_id: id}, members), do: MapSet.member?(members, id)
  defp wanted?(%{action: :unmark, issue_id: id}, members), do: not MapSet.member?(members, id)

  defp edit(document, {:set_trigger, name, trigger}, _now), do: QueueTriggers.set(document, name, trigger)
  defp edit(document, {:add, ids, opts}, now), do: ListMutations.add(document, ids, opts, DateTime.from_unix!(now, :millisecond))
  defp edit(document, {:remove, id}, _now), do: ListMutations.remove(document, id)
  defp edit(document, {:reorder, id, at}, _now), do: ListMutations.reorder(document, id, at)
  defp edit(document, {:add_edge, prerequisite, dependent}, _now), do: ListMutations.add_edge(document, prerequisite, dependent)

  defp open_members(state, {:add, ids, _}) do
    max_age = Settings.observation_max_age_ms(state.settings)

    case state.tracker.open_issue_labels(max_age) do
      {:ok, labels, observed_at} ->
        now = state.clock.()

        cond do
          observed_at > now or now - observed_at > max_age -> {:error, :inputs_unavailable}
          Enum.any?(ids, &(not Map.has_key?(labels, &1))) -> {:error, :closed}
          true -> :ok
        end

      _ ->
        {:error, :inputs_unavailable}
    end
  end

  defp open_members(_state, _command), do: :ok

  defp intent({action, id}, observations, state) do
    marker = "#{state.settings.tracker.github.label_prefix}:queued"
    labels = if observations[id], do: observations[id].labels, else: []
    targets = if action == :mark, do: Enum.uniq(labels ++ [marker]), else: Enum.reject(labels, &(&1 == marker))
    # Persist the request as well as each attempt, so pacing or a crash cannot lose marker work.
    %Intent{id: Ecto.UUID.generate(), issue_id: id, action: action, target_labels: targets, recorded_at_ms: state.clock.(), outcome: nil}
  end
end
