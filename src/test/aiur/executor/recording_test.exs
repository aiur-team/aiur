defmodule Aiur.Executor.RecordingTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Executor.{Claims, StatePaths}
  alias Aiur.{ExecutorListener, ExecutorWakeInbox}

  @listener_name Aiur.ExecutorListener.RecordingTest
  @inbox_name Aiur.ExecutorWakeInbox.RecordingTest
  @late_inbox_name Aiur.ExecutorWakeInbox.RecordingTestLate

  setup do
    # Point every StatePaths lookup at a directory this case owns, so the
    # inbox's durable ledger is this test's and nothing else's.
    dir = Aiur.TestSupport.tmp_root!("aiur-executor-recording")
    File.mkdir_p!(dir)
    Application.put_env(:aiur, :executor_state_dir, dir)

    on_exit(fn ->
      Application.delete_env(:aiur, :executor_state_dir)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      File.rm_rf!(dir)
      :ok
    end)

    :ok
  end

  defp start_inbox(opts \\ []) do
    {id, opts} = Keyword.pop(opts, :id, @inbox_name)
    start_supervised!({ExecutorWakeInbox, Keyword.merge([name: @inbox_name, debounce_ms: 0], opts)}, id: id)
  end

  test "recording is armed without --executor" do
    specs =
      Aiur.Application.child_specs(
        interactive_cli?: false,
        headless?: true,
        dashboard?: false,
        telemetry?: false,
        executor_mode?: false,
        recording?: true
      )

    assert Aiur.ExecutorWakeInbox in specs
    assert Aiur.ExecutorListener in specs
    assert Aiur.Executor.Claims in specs
  end

  test "a run without --executor records PR-lifecycle, CI and attention wakes" do
    Application.put_env(:aiur, :executor_mode, false)
    on_exit(fn -> Application.delete_env(:aiur, :executor_mode) end)

    start_inbox()
    start_supervised!({ExecutorListener, name: @listener_name, inbox: @inbox_name, resubscribe_interval_ms: :infinity})

    publish_operational_events()

    records = eventually_pending(3)

    # Assert by count, and by which classes actually landed.
    assert length(records) == 3

    assert Enum.sort(Enum.map(records, & &1["topic_class"])) ==
             ["ticket.agent.attention.review", "ticket.ci.failed", "ticket.pr.opened"]

    # The trust boundary is unchanged: identifier-only projections, no free text.
    Enum.each(records, fn record ->
      refute Map.has_key?(record, "message")
      refute Map.has_key?(record, "body")
      refute Map.has_key?(record, "title")
    end)
  end

  test "an agent attaching after the run replays what was published before it started" do
    start_inbox()
    start_supervised!({ExecutorListener, name: @listener_name, inbox: @inbox_name, resubscribe_interval_ms: :infinity})

    publish_operational_events()
    _recorded = eventually_pending(3)

    # The "late" agent starts only now, and still sees every record written
    # before it existed, because the inbox is durable rather than in-memory.
    late =
      start_supervised!({ExecutorWakeInbox, name: @late_inbox_name, debounce_ms: 0}, id: :late_inbox)

    assert is_pid(late)

    late_records = ExecutorWakeInbox.pending(@late_inbox_name)
    assert length(late_records) == 3
  end

  test "records survive a restart: appends land in one durable ledger across boots" do
    start_inbox(id: :boot_one)
    :ok = ExecutorWakeInbox.enqueue(record(1, "1"), @inbox_name)
    _flushed = eventually_pending(1)

    path = StatePaths.wakes_path()
    stop_supervised!(:boot_one)

    # A restart used to begin a fresh, empty journal because the path resolved
    # to the current boot's log directory. It must now be the same file.
    start_inbox(id: :boot_two)
    :ok = ExecutorWakeInbox.enqueue(record(2, "2"), @inbox_name)
    _flushed = eventually_pending(2)

    assert StatePaths.wakes_path() == path
    assert length(read_ledger(path)) == 2
    refute String.contains?(path, "/log/")
  end

  test "a successor receives every record the previous owner never acknowledged" do
    start_inbox()
    claims = claims_opts()

    {:ok, _entry} = Claims.claim("owner-a", claims)

    for id <- 1..10, do: :ok = ExecutorWakeInbox.enqueue(record(id, Integer.to_string(id)), @inbox_name)
    all = eventually_pending(10)

    # The owner acknowledges the first four, then dies without acknowledging six.
    {acknowledged, unacknowledged} = Enum.split(Enum.sort_by(all, & &1["wake_id"]), 4)
    :ok = ExecutorWakeInbox.acknowledge_as("owner-a", acknowledged, @inbox_name)
    :ok = Claims.release("owner-a", claims)

    # Takeover resumes from the durable cursor.
    assert {:ok, %{"id" => "owner-b"}} = Claims.claim("owner-b", claims)

    successor = ExecutorWakeInbox.pending(@inbox_name)

    assert length(successor) == 6
    assert length(unacknowledged) == 6
    assert Enum.map(successor, & &1["wake_id"]) == Enum.map(unacknowledged, & &1["wake_id"])
  end

  test "a non-owner reads the stream without advancing the shared cursor" do
    start_inbox()
    claims = claims_opts()

    {:ok, _entry} = Claims.claim("owner-a", claims)
    {:ok, _observer} = Claims.observe("observer-b", claims)

    for id <- 1..5, do: :ok = ExecutorWakeInbox.enqueue(record(id, Integer.to_string(id)), @inbox_name)
    records = eventually_pending(5)

    before = ExecutorWakeInbox.cursor(@inbox_name)

    # The observer sees the same five records, and its acknowledge is refused.
    assert length(ExecutorWakeInbox.pending(@inbox_name)) == 5
    assert {:error, {:not_owner, owner}} = ExecutorWakeInbox.acknowledge_as("observer-b", records, @inbox_name)
    assert owner["id"] == "owner-a"
    assert ExecutorWakeInbox.cursor(@inbox_name) == before
    assert length(ExecutorWakeInbox.pending(@inbox_name)) == 5

    # The owner's acknowledge is the only one that moves it, and it is the path
    # that writes the roster's consumption evidence.
    assert :ok = ExecutorWakeInbox.acknowledge_as("owner-a", records, @inbox_name)
    assert ExecutorWakeInbox.cursor(@inbox_name) > before
    assert ExecutorWakeInbox.pending(@inbox_name) == []

    {:ok, owner_entry} = Claims.owner(claims)
    assert is_binary(owner_entry["last_acknowledged_at"])
    assert owner_entry["acknowledged_count"] == 1
    assert owner_entry["cursor_at_last_ack"] == ExecutorWakeInbox.cursor(@inbox_name)
  end

  test "unattended recording stays bounded" do
    max = 25
    start_inbox(max_records: max)

    # Nobody ever claims or acknowledges — the always-on case that used to grow
    # without limit because only consumed records were trimmed.
    for id <- 1..(max * 4) do
      :ok = ExecutorWakeInbox.enqueue(record(id, Integer.to_string(id)), @inbox_name)
      Process.sleep(1)
    end

    _settled = eventually(fn -> length(ExecutorWakeInbox.pending(@inbox_name)) <= max end)

    # The bound is real, not an average, and it holds with no consumer at all.
    assert length(read_ledger(StatePaths.wakes_path())) <= max
    assert length(ExecutorWakeInbox.pending(@inbox_name)) <= max

    # Evicting an unread record loses a wake, so it is never silent: the durable
    # cursor moves past the dropped range instead of leaving a gap a consumer
    # would replay forever.
    assert ExecutorWakeInbox.cursor(@inbox_name) == max * 4 - max
  end

  # The default claims path already resolves inside this case's state directory.
  defp claims_opts, do: []

  defp publish_operational_events do
    publish("ticket.42.pr.opened", %{"pr_number" => 7, "action" => "opened", "draft" => false})
    publish("ticket.42.ci.failed", %{"pr_number" => 7, "head_sha" => String.duplicate("a", 40), "conclusion" => "failure"})
    publish("ticket.42.agent.attention.review", %{"needs_attention" => true})
  end

  defp publish(topic, payload) do
    Publisher.publish(topic, payload, source: :internal)
  end

  defp record(id, ticket) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      "wake_id" => id,
      "event_id" => id,
      "topic" => "ticket.#{ticket}.pr.opened",
      "topic_class" => "ticket.pr.opened",
      "ticket" => ticket,
      "count" => 1,
      "first_seen_at" => now,
      "last_seen_at" => now
    }
  end

  defp read_ledger(path) do
    case File.read(path) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      _ -> []
    end
  end

  defp eventually_pending(count) do
    eventually(fn -> length(ExecutorWakeInbox.pending(@inbox_name)) >= count end)
    ExecutorWakeInbox.pending(@inbox_name)
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts <= 0 -> flunk("condition never held")
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end
end
