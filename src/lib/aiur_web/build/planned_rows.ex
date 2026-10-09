defmodule AiurWeb.Build.PlannedRows do
  @moduledoc "Pure planned rows in queue order, with independent queue-source health."
  alias AiurWeb.Build.{PlannedGraph, PlannedSource}
  @planned ~w(waiting ready promoted overridden promoted_unauthorized held failed_prerequisite unknown)a
  @terminal ~w(completed cancelled removed)a
  @type cue :: %{
          held: String.t() | nil,
          promoted: integer() | nil,
          wait: pos_integer() | nil,
          waitAny: boolean(),
          failed: %{by: pos_integer(), blocks: [pos_integer()]} | nil,
          blockedChain: boolean(),
          unknown: boolean()
        }
  @type row :: %{id: String.t(), num: pos_integer(), sec: String.t(), status: String.t(), ord: non_neg_integer(), qpos: pos_integer() | nil, wave: pos_integer(), deps: [String.t()], cue: cue()}
  @type source :: %{state: String.t(), observed_at: integer() | nil, reason: String.t() | nil}
  @type result :: %{rows: [row()], source: source()}

  @spec read(keyword()) :: result()
  def read(opts \\ []) do
    queue = Keyword.get(opts, :queue, Aiur.BuildQueue)
    history = Keyword.get(opts, :history, Aiur.BuildOrder.History)
    show = if Code.ensure_loaded?(queue), do: safely(fn -> queue.show() end), else: {:error, :not_installed}
    snapshot = Keyword.get_lazy(opts, :history_snapshot, fn -> safely(fn -> history.snapshot([]) end) end)
    build(show, snapshot, opts)
  end

  @spec build(map() | {:error, term()}, {:ok, map()} | {:error, term()}, keyword()) :: result()
  def build(show, history, opts \\ []) do
    history = history_rows(history)
    live = live_items(show)
    planned = Enum.filter(live, fn {item, _queue} -> available?(show) and item.state in @planned and not closed?(history[item.number]) end)
    graph = PlannedGraph.build(planned, live)
    active = Keyword.get(opts, :active, MapSet.new())
    rows = Enum.map(planned, fn {item, queue} -> row(item, queue, graph, active) end)
    rows = rows ++ todo_rows(history, live, active, Keyword.get(opts, :todo_label))
    rows = rows |> Enum.with_index() |> Enum.map(fn {row, ord} -> %{row | ord: ord, qpos: if(row.qpos, do: ord + 1)} end)
    %{rows: rows, source: PlannedSource.build(show)}
  end

  defp safely(fun) do
    fun.()
  rescue
    _error -> {:error, :read_failed}
  catch
    :exit, _reason -> {:error, :read_failed}
  end

  defp history_rows({:ok, %{rows: rows}}), do: rows
  defp history_rows({:error, _reason}), do: %{}
  defp closed?(%{lifecycle: %{state: :closed}}), do: true
  defp closed?(_row), do: false

  defp available?(%{status: status}), do: status in [:running, :writes_paused]
  defp available?(_show), do: false

  defp live_items(%{queues: queues}) do
    queues
    |> Enum.flat_map(fn queue -> Enum.map(queue.items, &{&1, queue}) end)
    |> Enum.reject(fn {item, _queue} -> item.state in @terminal end)
    |> Enum.uniq_by(fn {item, _queue} -> item.number end)
  end

  defp live_items(_show), do: []

  defp row(item, queue, graph, active) do
    failed = graph.failed[item.number]

    cue = %{
      held: held(item, queue),
      promoted: if(item.state == :promoted, do: milliseconds(item.promoted_at)),
      wait: if(is_nil(failed), do: waiting(item.prerequisites, active)),
      waitAny: Enum.any?(item.prerequisites, &(&1.verdict != :satisfied)),
      failed: failed,
      blockedChain: is_nil(failed) and MapSet.member?(graph.blocked, item.number),
      unknown: item.state == :unknown or item.verdict == :unknown
    }

    %{id: to_string(item.number), num: item.number, sec: "plan", status: "queued", ord: 0, qpos: 1, wave: graph.waves[item.number], deps: Enum.map(item.prerequisites, &to_string(&1.number)), cue: cue}
  end

  defp waiting(edges, active) do
    case Enum.find(edges, &(&1.verdict == :pending and MapSet.member?(active, &1.number))) do
      nil -> nil
      edge -> edge.number
    end
  end

  defp held(%{state: state}, %{held: true} = queue) when state in [:waiting, :ready, :held],
    do: "Held · queue #{queue.name || queue.queue_id} is held"

  defp held(%{state: :promoted_unauthorized}, _queue), do: "Held · dispatch not authorized"

  defp held(item, _queue) do
    case {Map.get(item, :hold_by), Map.get(item, :hold_reason), item.state} do
      {by, reason, _state} when is_binary(by) and is_binary(reason) -> "Held by #{by} · #{reason}"
      {by, _reason, _state} when is_binary(by) -> "Held by #{by}"
      {_by, reason, _state} when is_binary(reason) -> "Held · #{reason}"
      {_by, _reason, :held} -> "Held · no actor or reason recorded"
      _facts -> nil
    end
  end

  defp milliseconds(%DateTime{} = time), do: DateTime.to_unix(time, :millisecond)
  defp milliseconds(_time), do: nil

  defp todo_rows(_history, _live, _active, nil), do: []

  defp todo_rows(history, live, active, label) do
    members = MapSet.new(live, fn {item, _queue} -> item.number end)

    history
    |> Map.values()
    |> Enum.filter(&todo?(&1, label, members, active))
    |> Enum.sort_by(&{milliseconds(&1.created_at) || :unknown, &1.number})
    |> Enum.map(&todo_row/1)
  end

  defp todo?(row, label, members, active),
    do:
      row.lifecycle.state == :open and is_list(row.labels) and label in row.labels and
        not MapSet.member?(members, row.number) and not MapSet.member?(active, row.number)

  defp todo_row(row),
    do: %{
      id: to_string(row.number),
      num: row.number,
      sec: "plan",
      status: "queued",
      ord: 0,
      qpos: nil,
      wave: 1,
      deps: [],
      cue: %{held: nil, promoted: nil, wait: nil, waitAny: false, failed: nil, blockedChain: false, unknown: false}
    }
end
