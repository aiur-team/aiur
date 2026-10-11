defmodule Aiur.ExecutorWakeInboxTrimTest do
  use Aiur.TestSupport

  alias Aiur.ExecutorWakeInbox

  @cap 10
  @low 8

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-wake-inbox-trim")
    on_exit(fn -> File.rm_rf!(root) end)

    opts = [
      name: __MODULE__,
      debounce_ms: 0,
      max_records: @cap,
      path: Path.join(root, "wakes.ndjson"),
      cursor_path: Path.join(root, "cursor.json"),
      pending_path: Path.join(root, "pending.json")
    ]

    Application.put_env(:aiur, :executor_wake_overflow_alerts?, false)
    on_exit(fn -> Application.delete_env(:aiur, :executor_wake_overflow_alerts?) end)
    start_supervised!({ExecutorWakeInbox, opts})
    %{path: opts[:path]}
  end

  # The trim renames a new file into place, so a `tail -F` follower re-reads the
  # whole journal each time it happens. Trimming on every append at the cap
  # replayed the full history per wake (#4166).
  test "past the cap the journal is rewritten once per low-watermark window, not per append", %{path: path} do
    appends = 30

    {rewrites, seen, _last, _inode} =
      Enum.reduce(1..(@cap + appends), {0, [], 0, nil}, fn id, {rewrites, seen, last, inode} ->
        append(path, id)
        now = File.stat!(path).inode
        # A wake_id-keyed reader: a rename replays the file, the filter drops what it already printed.
        fresh = path |> wake_ids() |> Enum.filter(&(&1 > last))
        rewrites = if inode && now != inode, do: rewrites + 1, else: rewrites
        {rewrites, seen ++ fresh, id, now}
      end)

    assert rewrites > 0
    assert rewrites <= ceil(appends / (@cap - @low))
    assert seen == Enum.to_list(1..(@cap + appends))
    assert length(wake_ids(path)) in @low..@cap
  end

  defp append(path, id) do
    record = %{"topic" => "ticket.#{id}.branch.push", "topic_class" => "ticket.branch.push", "event_id" => id, "ticket" => "#{id}"}
    :ok = ExecutorWakeInbox.enqueue(record, __MODULE__)
    assert eventually(fn -> List.last(wake_ids(path)) == id and :sys.get_state(__MODULE__).pending == %{} end)
  end

  defp wake_ids(path) do
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(&1)["wake_id"])
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: false
  defp eventually(fun, attempts), do: fun.() || (Process.sleep(5) && eventually(fun, attempts - 1))
end
