defmodule Aiur.VoiceConverse.Host.LiveContext do
  @moduledoc "Translates target-scoped Exchange events to portable voice context messages."
  use GenServer

  alias Aiur.Events.Exchange
  alias Aiur.VoiceConverse.Host.{BriefingSource, CommandSource, Worker}
  alias VoiceConverse.Briefing

  @spec subscribe(Worker.t() | :executor, pid(), :briefing | :commands, keyword()) :: :ok | :unsupported
  def subscribe(target, subscriber, kind, opts \\ []) do
    case GenServer.start(__MODULE__, {target, subscriber, kind, opts}) do
      {:ok, _pid} -> :ok
      _ -> :unsupported
    end
  end

  @impl true
  def init({target, subscriber, kind, opts}) do
    exchange = Keyword.get(opts, :exchange, Exchange)
    monitor = Process.monitor(subscriber)

    try do
      Enum.each(patterns(target), &Exchange.subscribe(&1, exchange))
      subscribe_live(target, kind, opts)
      {:ok, %{target: target, subscriber: subscriber, monitor: monitor, kind: kind, opts: opts}}
    catch
      :exit, _ -> {:stop, :exchange_unavailable}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state), do: {:stop, :normal, state}

  def handle_info({:event, %{topic: topic} = event}, state) when is_binary(topic) do
    dispatch(suffix(topic, state.target), event, state)
    {:noreply, state}
  end

  def handle_info({:live_conversation_changed, %{state: :ended}}, state) do
    notify(state, :target_gone)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp subscribe_live(%Worker{live_source: source}, :briefing, opts) when not is_nil(source) do
    live = Keyword.get(opts, :live, Aiur.LiveConversation)
    live.subscribe(source)
  end

  defp subscribe_live(_target, _kind, _opts), do: :ok

  defp patterns(%Worker{identity: identity}), do: ["ticket.#{identity.identifier}.#"]
  defp patterns(:executor), do: ["system.#", "executor.#"]

  defp suffix(topic, %Worker{identity: identity}), do: String.replace_prefix(topic, "ticket.#{identity.identifier}.", "")
  defp suffix(topic, :executor), do: topic

  defp dispatch("agent.progress.status", event, %{kind: :briefing} = state) do
    payload = value(event, :payload) || event

    if is_map(payload), do: notify(state, {:briefing, status_card(payload)})
  end

  defp status_card(payload) do
    now = DateTime.utc_now()
    fields = [current_task: :doing, summary: :why, next_steps: :next, waiting_on: :waiting_on, questions: :asks]
    Enum.reduce(fields, %Briefing{}, fn {key, source}, card -> put_field(card, key, value(payload, source), now) end)
  end

  defp put_field(card, key, text, now) when is_binary(text) do
    Map.put(card, key, %{value: status_value(key, text), observed_at: now, max_age_s: 30})
  end

  defp put_field(card, _key, _other, _now), do: card

  defp status_value(key, "") when key in [:questions, :next_steps], do: []
  defp status_value(key, text) when key in [:questions, :next_steps], do: [text]
  defp status_value(_key, text), do: text

  defp dispatch("agent.decision." <> action, event, %{kind: :commands} = state), do: command(action, event, state)
  defp dispatch("executor.decision." <> action, event, %{kind: :commands} = state), do: command(action, event, state)

  defp dispatch("pr." <> action, _event, %{kind: :briefing} = state) when action in ["opened", "merged", "closed", "closed_unmerged"] do
    notify(state, {:context_update, "PR #{action}", []})
    notify(state, {:briefing, briefing(state)})
  end

  defp dispatch("agent.phase." <> phase, _event, %{kind: :briefing} = state)
       when phase in ~w(brainstorm.start brainstorm.end plan.start plan.end work.start work.end review.start review.end) do
    notify(state, {:context_update, "Phase: #{phase}", []})
    notify(state, {:briefing, briefing(state)})
  end

  defp dispatch("agent.ended", _event, %{kind: :briefing} = state), do: notify(state, :target_gone)

  defp dispatch(topic, event, %{target: :executor, kind: :briefing} = state) do
    cond do
      Regex.match?(~r/^system\.build_order\.[^.]+\.progress$/, topic) and is_integer(value(event, :percent)) ->
        notify(state, {:context_update, "Build order progress: #{value(event, :percent)}%", []})

      topic == "executor.state.changed" and is_binary(value(event, :state)) ->
        notify(state, {:context_update, "Executor state: #{value(event, :state)}", []})

      topic == "system.blockers.changed" and is_integer(value(event, :count)) ->
        notify(state, {:context_update, "Blockers: #{value(event, :count)}", []})

      true ->
        :ok
    end
  end

  defp dispatch(_topic, _event, _state), do: :ok

  defp command(action, event, state) when action in ["requested", "human-needed"] do
    id = value(event, :decision_id)
    question = value(event, :question) || command_question(state, id)
    if is_binary(question), do: notify(state, {:context_update, "New Command: #{question}", []})
  end

  defp command(action, event, state) when action in ["resolved", "answered", "dismissed", "expired", "mooted"] do
    case value(event, :decision_id) do
      id when is_binary(id) -> notify(state, {:command_resolved, id})
      _ -> :ok
    end
  end

  defp command(_action, _event, _state), do: :ok

  defp command_question(state, id) do
    case CommandSource.open(state.target, state.opts) do
      {:ok, commands} -> commands |> Enum.find(&(&1.id == id)) |> then(&if(&1, do: &1.question))
      _ -> nil
    end
  end

  defp briefing(state) do
    case BriefingSource.brief(state.target, state.opts) do
      {:ok, %Briefing{} = card} -> card
      _ -> %Briefing{gaps: ["Briefing data unavailable"]}
    end
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp notify(state, message), do: send(state.subscriber, message)
end
