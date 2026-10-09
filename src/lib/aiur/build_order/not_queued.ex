defmodule Aiur.BuildOrder.NotQueued do
  @moduledoc "Pure not-queued rows from held open-ticket and queue snapshots."

  alias Aiur.BuildOrder.Metadata
  alias Aiur.GitHub.{Config, Labels, StatePolicy}
  alias Aiur.OpenTicketSource.Snapshot

  @pts {1, 2, 3, 5, 8}
  @type state :: :ok | :stale | :unavailable | :unsupported
  @type row :: %{num: pos_integer(), title: String.t(), cx: 1..5 | nil, pts: 1 | 2 | 3 | 5 | 8 | nil, created: DateTime.t() | nil, ord: pos_integer(), sec: String.t(), status: String.t()}
  @type result :: %{state: state(), reasons: [atom()], observed_at: DateTime.t() | nil, truncated?: boolean(), skipped: non_neg_integer(), rows: [row()]}

  @spec points(term()) :: 1 | 2 | 3 | 5 | 8 | nil
  def points(complexity) when complexity in 1..5, do: elem(@pts, complexity - 1)
  def points(_complexity), do: nil

  @spec build(Snapshot.t(), term(), keyword()) :: result()
  def build(snapshot, queue, opts \\ []) do
    {open_state, open_reasons} = open_state(snapshot.status)
    {queue_state, queue_reasons} = queue_state(queue)
    state = worst_state(open_state, queue_state)
    {rows, skipped} = if state in [:unavailable, :unsupported], do: {[], 0}, else: rows(snapshot.tickets, queue, opts)

    %{
      state: state,
      reasons: open_reasons ++ queue_reasons,
      observed_at: observed_at(snapshot.observed_at, queue),
      truncated?: snapshot.truncated?,
      skipped: skipped,
      rows: rows
    }
  end

  defp open_state(:available), do: {:ok, []}
  defp open_state(:stale), do: {:stale, [:open_tickets_stale]}
  defp open_state(:unavailable), do: {:unavailable, [:open_tickets_unavailable]}
  defp open_state(:unsupported), do: {:unsupported, [:tracker_unsupported]}

  defp queue_state(%{status: status} = queue) when status in [:running, :writes_paused] do
    freshness = Enum.map(sources(queue), &Map.get(&1, :freshness))

    cond do
      freshness == [] or Enum.any?(freshness, &(&1 not in [:current, :stale])) -> {:stale, [:queue_freshness_unknown]}
      :stale in freshness -> {:stale, [:queue_stale]}
      true -> {:ok, []}
    end
  end

  defp queue_state(%{status: :disabled}), do: {:ok, [:queue_disabled]}
  defp queue_state(%{status: :unsupported_tracker}), do: {:ok, [:queue_unsupported]}
  defp queue_state(%{status: :store_unavailable}), do: {:unavailable, [:queue_unavailable]}
  defp queue_state({:error, _reason}), do: {:unavailable, [:queue_read_failed]}
  defp queue_state(_queue), do: {:unavailable, [:queue_status_unknown]}

  defp worst_state(:unsupported, _queue), do: :unsupported
  defp worst_state(open, queue) when :unavailable in [open, queue], do: :unavailable
  defp worst_state(open, queue) when :stale in [open, queue], do: :stale
  defp worst_state(_open, _queue), do: :ok

  defp sources(queue), do: queue |> Map.get(:sources, %{}) |> Map.values()

  defp observed_at(open, %{status: status}) when status in [:disabled, :unsupported_tracker], do: open

  defp observed_at(open, %{status: status} = queue) when status in [:running, :writes_paused] do
    times = Enum.map(sources(queue), &Map.get(&1, :observed_at))
    if times == [] or Enum.any?([open | times], &is_nil/1), do: nil, else: Enum.min([open | times], DateTime)
  end

  defp observed_at(_open, _queue), do: nil

  defp rows(tickets, queue, opts) do
    prefix = opts |> Keyword.get_lazy(:label_prefix, &Config.label_prefix/0) |> String.downcase()
    labels = Labels.state_labels(prefix) |> Enum.reject(&StatePolicy.terminal_state_label?(&1, prefix)) |> MapSet.new()
    excluded = MapSet.union(queued(queue), Keyword.get(opts, :active, MapSet.new()))
    {rows, skipped} = Enum.reduce(tickets, {[], 0}, &collect(&1, &2, excluded, labels))
    {Enum.sort_by(rows, & &1.num), skipped}
  end

  defp queued(%{status: status}) when status in [:disabled, :unsupported_tracker], do: MapSet.new()

  defp queued(queue) do
    for queue <- Map.get(queue, :queues, []), item <- queue.items, item.state not in [:removed, :completed, :cancelled], into: MapSet.new(), do: item.number
  end

  defp collect(ticket, {rows, skipped}, excluded, active_labels) do
    case number(ticket) do
      nil -> {rows, skipped + 1}
      num -> if MapSet.member?(excluded, num) or Enum.any?(ticket.labels, &MapSet.member?(active_labels, &1)), do: {rows, skipped}, else: {[row(ticket, num) | rows], skipped}
    end
  end

  defp number(%{identifier: id, title: title}) when is_binary(id) and is_binary(title) do
    case Integer.parse(id) do
      {num, ""} when num > 0 -> num
      _ -> nil
    end
  end

  defp number(_ticket), do: nil

  defp row(ticket, num) do
    complexity = Metadata.parse(ticket.labels).complexity
    cx = if complexity == :unknown, do: nil, else: complexity
    %{num: num, title: ticket.title, cx: cx, pts: points(cx), created: ticket.created_at, ord: num, sec: "nq", status: "open"}
  end
end
