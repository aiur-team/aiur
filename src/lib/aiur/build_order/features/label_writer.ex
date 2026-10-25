defmodule Aiur.BuildOrder.Features.LabelWriter do
  @moduledoc false
  alias Aiur.BuildOrder.Features.LabelStateStore

  # ponytail: independent hourly safety cap; coordinate daemon writers if combined traffic reaches secondary limits.
  @hourly_limit 200
  @spec buckets(DateTime.t(), pos_integer()) :: map()
  def buckets(now, limit), do: %{minute: {now, limit}, hour: {now, @hourly_limit}, limit: limit}

  @spec run(map()) :: map()
  def run(%{tracker_status: status} = state) when status != :ok, do: state
  def run(%{writes: :paused} = state), do: state
  def run(%{available?: false} = state), do: state

  def run(state) do
    pending =
      state.entries
      |> Enum.filter(fn {key, entry} -> entry.state in [:pending_label, :pending_unlabel] and not MapSet.member?(state.attempted, key) end)
      |> Enum.sort_by(fn {key, entry} -> {DateTime.to_unix(entry.queued_at, :microsecond), key} end)

    Enum.reduce_while(pending, refill(state), fn {key, _}, acc ->
      next = write(key, acc)
      if next.writes == :paused or next.tracker_status != :ok or not next.available? or empty?(next.buckets), do: {:halt, next}, else: {:cont, next}
    end)
  end

  defp refill(state) do
    now = state.clock.()
    buckets = state.buckets
    buckets = %{buckets | minute: refill_bucket(buckets.minute, now, 60, buckets.limit), hour: refill_bucket(buckets.hour, now, 3_600, @hourly_limit)}
    %{state | buckets: buckets}
  end

  defp refill_bucket({at, left}, now, seconds, max) do
    if DateTime.diff(now, at) >= seconds, do: {now, max}, else: {at, left}
  end

  defp empty?(%{minute: {_, m}, hour: {_, h}}), do: m == 0 or h == 0

  defp spend(state) do
    %{minute: {ma, m}, hour: {ha, h}} = state.buckets
    %{state | buckets: %{state.buckets | minute: {ma, m - 1}, hour: {ha, h - 1}}}
  end

  defp write(_key, %{buckets: %{minute: {_, 0}}} = state), do: state
  defp write(_key, %{buckets: %{hour: {_, 0}}} = state), do: state

  defp write({slug, _n} = key, state) do
    tracker = state.tracker || Aiur.Tracker.adapter()
    Code.ensure_loaded(tracker)
    if not MapSet.member?(state.ensured, slug) and function_exported?(tracker, :ensure_labels, 1), do: ensure(key, tracker, spend(state)), else: label(key, tracker, state)
  end

  defp ensure({slug, _} = key, tracker, state) do
    case tracker.ensure_labels(["feature:" <> slug]) do
      :ok ->
        state = persist(%{state | ensured: MapSet.put(state.ensured, slug)})
        if state.available? and not empty?(state.buckets), do: label(key, tracker, state), else: state

      {:error, reason} ->
        outcome(key, {:error, reason}, state)
    end
  end

  defp label({slug, n} = key, tracker, state) do
    operation = if state.entries[key].state == :pending_label, do: :add_label, else: :remove_label
    result = apply(tracker, operation, [to_string(n), "feature:" <> slug])
    outcome(key, result, spend(state))
  end

  defp outcome(key, :ok, state) do
    entry = state.entries[key]
    next = if entry.state == :pending_label, do: :labelled, else: :unlabelled
    persist(%{state | entries: Map.put(state.entries, key, %{entry | state: next, written_at: state.clock.(), attempts: 0, last_error: nil})})
  end

  defp outcome(key, {:error, reason}, state) do
    state = %{state | attempted: MapSet.put(state.attempted, key)}
    entry = state.entries[key]
    error = inspect(reason, limit: 20) |> String.slice(0, 200)

    cond do
      paused?(reason) ->
        persist(%{state | writes: :paused, entries: Map.put(state.entries, key, %{entry | last_error: error})})

      reason == :unsupported ->
        persist(%{state | tracker_status: :unsupported})

      true ->
        attempts = entry.attempts + 1
        failed? = attempts >= 5 or (entry.state == :pending_label and gone?(reason))
        entry = %{entry | attempts: attempts, last_error: error, failed_from: if(failed?, do: entry.state, else: nil), state: if(failed?, do: :failed, else: entry.state)}
        persist(%{state | entries: Map.put(state.entries, key, entry)})
    end
  end

  defp paused?({:github, kind, _}), do: kind in [:rate_limited, :local_hold, :auth]
  defp paused?({:github_api_status, status, _}), do: status in [401, 403, 429]
  defp paused?({:github_api_request, {:aiur, :locally_held, _}}), do: true
  defp paused?({:github_api_request, :github_budget_broker_timeout}), do: true
  defp paused?(:github_budget_broker_timeout), do: true
  defp paused?(_), do: false
  defp gone?({:github, :http, %{status: status}}), do: status in [404, 410]
  defp gone?(_), do: false

  @spec persist(map()) :: map()
  def persist(state) do
    case LabelStateStore.save(state.path, state.entries) do
      :ok -> %{state | available?: true}
      {:error, _reason} -> %{state | available?: false, writes: :paused}
    end
  end
end
