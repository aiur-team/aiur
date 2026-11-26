defmodule Aiur.BuildOrder.History.LabelBackfill.Writer do
  @moduledoc false
  alias Aiur.BuildOrder.History.LabelBackfill.{Checkpoint, Rules, Sources}
  alias Aiur.Orchestrator.TicketTransition

  @spec process_one(String.t(), map()) :: map()
  def process_one(id, %{unavailable: nil, data: %{run: %{state: :running}}} = state) do
    if held?(state) or not Map.has_key?(state.data.items, id) do
      state
    else
      plan = state.batch.plan || Sources.plan(state.readers, Map.to_list(state.data.run))
      state = %{state | batch: %{state.batch | plan: plan}}
      decisions = Map.new(plan.items, &{Rules.item_key(&1), &1})
      process(id, decisions, plan.unknown, state)
    end
  end

  def process_one(_id, state), do: state

  defp held?(state), do: match?(%DateTime{}, state.data.run.hold_until) and DateTime.compare(state.clock.(), state.data.run.hold_until) == :lt

  defp process(_id, _decisions, _unknown, %{unavailable: reason} = state) when not is_nil(reason), do: state
  defp process(_id, _decisions, _unknown, %{data: %{run: %{state: status}}} = state) when status != :running, do: state

  defp process(id, decisions, unknown, state) do
    item = state.data.items[id]

    cond do
      held?(state) -> state
      item.status == :written_unmarked -> mark(id, state)
      item.status != :pending -> state
      not Map.has_key?(decisions, id) and unknown != [] -> state
      not Map.has_key?(decisions, id) -> put_item(state, id, %{status: :skipped, reason: :changed}) |> persist()
      true -> decide(id, decisions[id], state)
    end
  end

  defp decide(id, %{decision: {:done, :already_present}, seen_at: seen}, state) do
    state |> put_item(id, %{status: :written_unmarked, seen_at: seen}) |> persist() |> mark(id)
  end

  defp decide(_id, %{decision: {:defer, _}}, state), do: state
  defp decide(id, %{decision: {:skip, reason}}, state), do: put_item(state, id, %{status: :skipped, reason: reason}) |> persist()
  defp decide(id, %{decision: :not_item}, state), do: put_item(state, id, %{status: :skipped, reason: :changed}) |> persist()

  defp decide(id, %{decision: :write}, state) do
    case Sources.current?(state.data.items[id], state.readers) do
      true -> write(id, state)
      false -> put_item(state, id, %{status: :skipped, reason: :changed}) |> persist()
      :unknown -> state
    end
  end

  defp write(id, state) do
    item = state.data.items[id]

    if item.kind == :feature and item.label not in state.data.ensured do
      request(id, :ensure, state)
    else
      request(id, :label, state)
    end
  end

  defp request(id, operation, state) do
    now = state.clock.()

    if Rules.window_allows?(state.data.window, state.data.run.per_hour, state.per_minute, now) do
      next = persist(%{state | data: %{state.data | window: [now | Rules.recent(state.data.window, now)]}})
      if is_nil(next.unavailable), do: perform(id, operation, next), else: next
    else
      state
    end
  end

  defp perform(id, operation, state) do
    item = state.data.items[id]

    result =
      if operation == :ensure,
        do: TicketTransition.with_writer(:history_label_backfill, fn -> state.tracker.ensure_labels([item.label]) end),
        else: TicketTransition.write_marker(to_string(item.ticket), :add, item.label, writer: :history_label_backfill, tracker: state.tracker)

    case {operation, Rules.on_result(result, state.clock.())} do
      {:ensure, :written} ->
        persist(%{state | data: %{state.data | ensured: Enum.uniq([item.label | state.data.ensured])}})

      {_, effect} ->
        outcome(id, effect, state)
    end
  end

  defp outcome(id, :written, state) do
    now = state.clock.()
    state |> put_item(id, %{status: :written_unmarked, at: now, seen_at: now}) |> persist() |> mark(id)
  end

  defp outcome(_id, {:hold, at}, state), do: update_run(state, %{hold_until: at}) |> persist()
  defp outcome(_id, {:stop, reason}, state), do: update_run(state, %{state: :stopped, stop_reason: reason}) |> persist()
  defp outcome(id, {:failed, reason}, state), do: put_item(state, id, %{status: :failed, reason: reason}) |> persist()

  defp outcome(id, {:retry, error}, state) do
    attempts = state.data.items[id].attempts + 1
    put_item(state, id, %{attempts: attempts, status: if(attempts >= 5, do: :failed, else: :pending), last_error: error}) |> persist()
  end

  defp mark(state, id) when is_map(state), do: mark(id, state)
  defp mark(_id, %{unavailable: reason} = state) when not is_nil(reason), do: state

  defp mark(id, state) do
    item = state.data.items[id]
    result = if item.kind == :feature, do: state.readers.mark.(item.slug_or_epic, item.ticket, %{written_at: item.at, seen_at: item.seen_at}), else: :ok

    case result do
      :ok -> put_item(state, id, %{status: if(item.at, do: :written, else: :already_present)}) |> persist()
      {:error, :not_held} -> put_item(state, id, %{status: :written}) |> persist()
      {:error, {:not_member, _}} -> put_item(state, id, %{status: :written, projection: :left}) |> persist()
      _ -> state
    end
  end

  @spec finish(map()) :: map()
  def finish(state) do
    if Enum.all?(state.data.items, fn {_, item} -> item.status not in [:pending, :written_unmarked] end) and state.data.run.state == :running,
      do: update_run(state, %{state: :finished}) |> persist(),
      else: state
  end

  defp put_item(state, id, fields), do: %{state | data: %{state.data | items: Map.update!(state.data.items, id, &Map.merge(&1, fields))}}
  @spec update_run(map(), map()) :: map()
  def update_run(state, fields), do: %{state | data: %{state.data | run: Map.merge(state.data.run, fields)}}

  @spec persist(map()) :: map()
  def persist(state) do
    case Checkpoint.save(state.path, state.data, state.opts) do
      :ok -> state
      _ -> %{update_run(state, %{state: :stopped, stop_reason: :checkpoint_write_failed}) | unavailable: :checkpoint_write_failed}
    end
  end

  @spec status(map()) :: map()
  def status(%{unavailable: reason}) when not is_nil(reason), do: %{state: :unavailable, reason: reason}

  def status(state) do
    now = state.clock.()
    last = state.data.items |> Map.values() |> Enum.map(& &1.at) |> Enum.reject(&is_nil/1) |> Enum.max(DateTime, fn -> nil end)
    health = state.readers.health.()

    %{
      run: state.data.run,
      writes: if(held?(state), do: :held, else: state.data.run.state),
      requests_last_hour: length(Rules.recent(state.data.window, now)),
      counts: state.data.items |> Map.values() |> Enum.frequencies_by(& &1.status),
      last_write: age(last, now),
      history: age(if(health.state == :healthy, do: health.observed_at, else: nil), now),
      hold_remaining_ms: if(held?(state), do: DateTime.diff(state.data.run.hold_until, now, :millisecond), else: 0)
    }
  end

  defp age(%DateTime{} = at, now), do: %{observed_at: at, age_ms: max(DateTime.diff(now, at, :millisecond), 0), freshness: :known}
  defp age(_, _), do: %{observed_at: :unknown, age_ms: :unknown, freshness: :unknown}
end
