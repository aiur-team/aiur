defmodule Aiur.DurableRuntimeStateTest do
  @moduledoc """
  #2722: state that a restart must keep lives in the durable runtime state
  directory, not in the per-launch log directory that the launcher makes new
  on every launch. Each case simulates a restart by pointing `:log_file` at a
  new launch directory while the runtime state directory stays the same.
  """
  use ExUnit.Case, async: false

  alias Aiur.{AlertFeed, AlertLedger, LaunchStateAdoption, SessionHandle}
  alias Aiur.Config.Paths
  alias Aiur.Events.{IdGenerator, SubscriptionStore}
  alias Aiur.JsonStore

  @host "durable-state-host"

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur_durable_runtime_state")
    logs_parent = Path.join(root, "logs")
    state_dir = Path.join(root, "state")
    File.mkdir_p!(logs_parent)

    previous = Map.new([:log_file, :runtime_state_dir], &{&1, Application.get_env(:aiur, &1)})
    Application.put_env(:aiur, :runtime_state_dir, state_dir)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:aiur, key)
        {key, value} -> Application.put_env(:aiur, key, value)
      end)

      File.rm_rf(root)
    end)

    %{logs_parent: logs_parent, state_dir: state_dir}
  end

  # Points the daemon at a launcher-shaped launch log directory, as a restart
  # does, and returns that directory.
  defp launch(logs_parent, launch_name) do
    log_dir = Path.join([logs_parent, launch_name, "log"])
    File.mkdir_p!(log_dir)
    Application.put_env(:aiur, :log_file, Path.join(log_dir, "aiur.log"))
    log_dir
  end

  defp write_legacy!(log_dir, name, contents, mtime) do
    path = Path.join(log_dir, name)
    File.write!(path, contents)
    File.touch!(path, mtime)
    path
  end

  defp start_generator(opts) do
    {:ok, pid} = IdGenerator.start_link(Keyword.merge([name: nil, path: nil, batch_size: 5], opts))
    pid
  end

  describe "IdGenerator across a restart" do
    test "the counter lives in the runtime state dir, not the launch log dir", %{logs_parent: logs_parent, state_dir: state_dir} do
      log_dir = launch(logs_parent, "20260101T000000Z-100")

      assert IdGenerator.default_path() == Path.join(state_dir, "event-id.json")
      refute String.starts_with?(IdGenerator.default_path(), log_dir)
    end

    test "the first id after a restart is greater than every earlier id, even when the clock steps back",
         %{logs_parent: logs_parent} do
      launch(logs_parent, "20260101T000000Z-100")
      first_boot = start_generator([])
      issued = for _ <- 1..12, do: IdGenerator.next_id(first_boot)
      GenServer.stop(first_boot)

      # Restart: a new launch log dir, and a wall clock that is far behind.
      launch(logs_parent, "20260101T010000Z-200")
      second_boot = start_generator(clock: fn -> 1 end, legacy_counter_files: fn -> [] end)
      after_restart = IdGenerator.next_id(second_boot)
      GenServer.stop(second_boot)

      assert after_restart > Enum.max(issued)
    end

    test "a crash (no terminate) still never re-issues an id after a restart with a stepped-back clock",
         %{logs_parent: logs_parent} do
      Process.flag(:trap_exit, true)

      launch(logs_parent, "20260101T000000Z-100")
      first_boot = start_generator([])
      issued = for _ <- 1..7, do: IdGenerator.next_id(first_boot)
      Process.exit(first_boot, :kill)
      assert_receive {:EXIT, ^first_boot, :killed}, 1_000

      launch(logs_parent, "20260101T010000Z-200")
      second_boot = start_generator(clock: fn -> 1 end, legacy_counter_files: fn -> [] end)
      after_restart = IdGenerator.next_id(second_boot)
      GenServer.stop(second_boot)

      assert after_restart > Enum.max(issued)
    end

    test "migration seeds above every earlier launch's counter, not only the newest file, under a stepped-back clock",
         %{logs_parent: logs_parent, state_dir: state_dir} do
      legacy_name = "#{Paths.repo_name()}.event_id"
      high = 9_000_000_000_000_000

      # The older file (by mtime) holds the higher id: after a clock step back
      # the newest file is not the highest one.
      older = launch(logs_parent, "20260101T000000Z-100")
      write_legacy!(older, legacy_name, Jason.encode!(%{"last_id" => high - 50, "reserved_through" => high}), 1_000)
      newer = launch(logs_parent, "20260101T010000Z-200")
      write_legacy!(newer, legacy_name, Jason.encode!(%{"last_id" => 10, "reserved_through" => 60}), 2_000)

      launch(logs_parent, "20260101T020000Z-300")
      refute File.exists?(Path.join(state_dir, "event-id.json"))

      pid = start_generator(clock: fn -> 1 end)
      first = IdGenerator.next_id(pid)
      GenServer.stop(pid)

      assert first > high
      assert {:ok, %{"reserved_through" => reserved}} = JsonStore.read(Path.join(state_dir, "event-id.json"))
      assert reserved >= first
    end

    test "after migration, a later restart resumes from the durable file and ignores legacy counters",
         %{logs_parent: logs_parent} do
      launch(logs_parent, "20260101T000000Z-100")
      first_boot = start_generator([])
      issued = IdGenerator.next_id(first_boot)
      GenServer.stop(first_boot)

      calls = :counters.new(1, [])

      launch(logs_parent, "20260101T010000Z-200")

      second_boot =
        start_generator(
          clock: fn -> 1 end,
          legacy_counter_files: fn ->
            :counters.add(calls, 1, 1)
            []
          end
        )

      assert IdGenerator.next_id(second_boot) > issued
      GenServer.stop(second_boot)
      assert :counters.get(calls, 1) == 0
    end
  end

  describe "SubscriptionStore across a restart" do
    test "subscriptions and cursor survive a new launch log dir", %{logs_parent: logs_parent, state_dir: state_dir} do
      identifier = "durable-subs-#{System.unique_integer([:positive])}"
      launch(logs_parent, "20260101T000000Z-100")

      :ok = SubscriptionStore.attach(identifier)
      :ok = SubscriptionStore.add_subscription(identifier, "ticket.4242.branch.push", "manual:test")
      :ok = SubscriptionStore.advance_cursor(identifier, 77)
      :ok = SubscriptionStore.add_attention(identifier, "needs-review")
      :ok = SubscriptionStore.stop(identifier)

      assert String.starts_with?(SubscriptionStore.path_for(identifier), state_dir)

      launch(logs_parent, "20260101T010000Z-200")
      :ok = SubscriptionStore.attach(identifier)
      snapshot = SubscriptionStore.snapshot(identifier)
      :ok = SubscriptionStore.stop(identifier)

      assert Enum.map(snapshot.subscribed_to, & &1["topic"]) == ["ticket.4242.branch.push"]
      assert snapshot.last_seen_event_id == 77
      assert snapshot.open_attentions == ["needs-review"]
    end

    test "adopts the newest launch's files once, and a deleted file is not brought back",
         %{logs_parent: logs_parent, state_dir: state_dir} do
      repo = Paths.repo_name()
      payload = fn topic -> Jason.encode!(%{"subscribed_to" => [%{"topic" => topic, "reason" => "manual:test"}]}) end

      # The older launch has a file for ticket 1 that the newer launch had
      # already dropped; only the newer launch's snapshot is adopted.
      older = launch(logs_parent, "20260101T000000Z-100")
      write_legacy!(older, "#{repo}.1.subscriptions.json", payload.("ticket.1.x"), 1_000)
      write_legacy!(older, "#{repo}.2.subscriptions.json", payload.("ticket.2.old"), 1_000)
      newer = launch(logs_parent, "20260101T010000Z-200")
      write_legacy!(newer, "#{repo}.2.subscriptions.json", payload.("ticket.2.new"), 2_000)
      write_legacy!(newer, "otherrepo.3.subscriptions.json", payload.("ticket.3.x"), 2_000)

      launch(logs_parent, "20260101T020000Z-300")
      path2 = SubscriptionStore.path_for("2")

      assert {:ok, %{"subscribed_to" => [%{"topic" => "ticket.2.new"}]}} = JsonStore.read(path2)
      refute File.exists?(SubscriptionStore.path_for("1"))
      refute File.exists?(Path.join([state_dir, "subscriptions", "otherrepo.3.subscriptions.json"]))

      # Once: removing the adopted file and resolving again does not re-adopt.
      File.rm!(path2)
      write_legacy!(newer, "#{repo}.2.subscriptions.json", payload.("ticket.2.newer"), 3_000)
      refute File.exists?(SubscriptionStore.path_for("2"))
    end
  end

  describe "SessionHandle across a restart" do
    test "a saved handle survives a new launch log dir", %{logs_parent: logs_parent, state_dir: state_dir} do
      launch(logs_parent, "20260101T000000Z-100")
      :ok = SessionHandle.save("2722", %{backend: "codex", thread_id: "thread-1"}, hostname: @host)
      assert String.starts_with?(SessionHandle.path_for("2722"), state_dir)

      launch(logs_parent, "20260101T010000Z-200")

      assert {:ok, %{thread_id: "thread-1"}} = SessionHandle.load("2722", "codex", hostname: @host)
    end

    test "adopts a legacy handle once; a cleared handle stays cleared", %{logs_parent: logs_parent} do
      handle =
        Jason.encode!(%{
          "schema_version" => 1,
          "backend" => "codex",
          "thread_id" => "legacy-thread",
          "hostname" => @host
        })

      older = launch(logs_parent, "20260101T000000Z-100")
      write_legacy!(older, "#{Paths.repo_name()}.2722.session.json", handle, 1_000)

      launch(logs_parent, "20260101T010000Z-200")
      assert {:ok, %{thread_id: "legacy-thread"}} = SessionHandle.load("2722", "codex", hostname: @host)

      :ok = SessionHandle.clear("2722")
      assert SessionHandle.load("2722", "codex", hostname: @host) == :none
    end
  end

  describe "AlertLedger across a restart" do
    test "the alert feed keeps alerts from before a restart", %{logs_parent: logs_parent, state_dir: state_dir} do
      launch(logs_parent, "20260101T000000Z-100")

      :ok =
        AlertLedger.append(%{
          "topic" => "system.durable.check",
          "timestamp" => "2026-01-01T00:00:00Z",
          "needs_attention" => true
        })

      assert String.starts_with?(AlertLedger.path(), state_dir)

      launch(logs_parent, "20260101T010000Z-200")

      assert Enum.any?(AlertFeed.list(roots: []), &(&1["topic"] == "system.durable.check"))
      assert AlertFeed.condition_state("system.durable.check", roots: []) == :firing
    end

    test "adopts the newest legacy ledger and its backfill marker once", %{logs_parent: logs_parent} do
      name = Paths.project_name() <> ".alerts.ndjson"
      line = fn topic -> Jason.encode!(%{"event" => "alert", "topic" => topic, "timestamp" => "2026-01-01T00:00:00Z"}) <> "\n" end

      older = launch(logs_parent, "20260101T000000Z-100")
      write_legacy!(older, name, line.("system.old"), 1_000)
      newer = launch(logs_parent, "20260101T010000Z-200")
      write_legacy!(newer, name, line.("system.newest"), 2_000)
      write_legacy!(newer, name <> ".alerts.backfill", "complete\n", 2_000)

      launch(logs_parent, "20260101T020000Z-300")
      topics = Enum.map(AlertFeed.list(roots: []), & &1["topic"])

      assert topics == ["system.newest"]
      assert AlertLedger.backfilled?()

      # Once: a newer legacy ledger that appears later is not adopted.
      write_legacy!(newer, name, line.("system.after"), 3_000)
      launch(logs_parent, "20260101T030000Z-400")
      assert Enum.map(AlertFeed.list(roots: []), & &1["topic"]) == ["system.newest"]
    end
  end

  describe "LaunchStateAdoption" do
    test "only launcher-shaped sibling directories are scanned", %{logs_parent: logs_parent} do
      current = launch(logs_parent, "20260101T020000Z-300")
      earlier = Path.join([logs_parent, "20260101T000000Z-100", "log"])
      File.mkdir_p!(earlier)
      File.mkdir_p!(Path.join([logs_parent, "unrelated", "log"]))

      assert Enum.sort(LaunchStateAdoption.legacy_log_dirs()) == Enum.sort([current, earlier])

      # A non-launcher layout (custom --logs-root, a test root) has no siblings.
      custom = Path.join([logs_parent, "custom-root", "log"])
      File.mkdir_p!(custom)
      Application.put_env(:aiur, :log_file, Path.join(custom, "aiur.log"))
      assert LaunchStateAdoption.legacy_log_dirs() == [custom]
    end
  end
end
