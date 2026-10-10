defmodule Aiur.GitHub.ResourceStore.MemoryTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.AgentControlCLI
  alias Aiur.GitHub.ResourceStore
  alias Aiur.GitHub.ResourceStore.Memory

  @body_bytes 100 * 1024

  setup do
    on_exit(fn ->
      Application.delete_env(:aiur, :github_resource_store_max_body_bytes)
      ResourceStore.reset()
    end)

    ResourceStore.reset()
  end

  defp body(index), do: %{"number" => index, "body" => String.duplicate("x", @body_bytes)}

  # `index` doubles as the write order: a higher index was recorded later.
  defp entry(index) do
    %{data: body(index), data_version: "v#{index}", etag: "etag-#{index}", processed_at_ms: index, recorded_at_ms: index}
  end

  defp private_table(entries) do
    table = :ets.new(:memory_test, [:public, :set])
    :ets.insert(table, entries)
    table
  end

  describe "enforce/2" do
    test "loading more large bodies than the cap admits sheds the oldest and keeps the store under it" do
      table = private_table(for index <- 1..20, do: {{:issue, "owner", "repo", "#{index}"}, entry(index)})
      cap = 5 * @body_bytes + 1024

      stats = Memory.enforce(table, max_body_bytes: cap)

      held = for {{_type, _owner, _repo, id}, %{data: _body}} <- :ets.tab2list(table), do: String.to_integer(id)
      assert Enum.sort(held) == [16, 17, 18, 19, 20]
      assert stats.shed == 15
      assert stats.bodies == 5
      assert stats.entries == 20
      assert stats.body_bytes == held |> Enum.map(&:erlang.external_size(body(&1))) |> Enum.sum()
      assert stats.body_bytes <= cap
    end

    test "a shed entry keeps its validator, its processed mark and its clock" do
      key = {:issue, "owner", "repo", "1"}
      table = private_table([{key, entry(1)}, {{:issue, "owner", "repo", "2"}, entry(2)}])

      Memory.enforce(table, max_body_bytes: @body_bytes + 1024)

      assert :ets.lookup(table, key) == [{key, %{etag: "etag-1", processed_at_ms: 1, recorded_at_ms: 1}}]
    end

    test "the entry backstop sheds bodies from the oldest overflow entries only" do
      table = private_table(for index <- 1..4, do: {{:issue, "owner", "repo", "#{index}"}, entry(index)})

      stats = Memory.enforce(table, max_entries: 3)

      assert stats.shed == 1
      assert stats.entries == 4
      refute match?([{_key, %{data: _body}}], :ets.lookup(table, {:issue, "owner", "repo", "1"}))
      assert [{_key, %{data: %{"number" => 2}}}] = :ets.lookup(table, {:issue, "owner", "repo", "2"})
    end

    test "a table inside both bounds sheds nothing" do
      table = private_table([{{:issue, "owner", "repo", "1"}, entry(1)}])

      assert %{shed: 0, bodies: 1} = Memory.enforce(table, max_body_bytes: 2 * @body_bytes)
      assert [{_key, %{data: %{"number" => 1}}}] = :ets.lookup(table, {:issue, "owner", "repo", "1"})
    end
  end

  describe "the running store" do
    test "its sweep holds the bodies under the configured byte cap and reports what it shed" do
      cap = 4 * @body_bytes
      Application.put_env(:aiur, :github_resource_store_max_body_bytes, cap)
      store = Process.whereis(ResourceStore)
      test_pid = self()
      handler = "memory-test-#{inspect(test_pid)}"

      :telemetry.attach(
        handler,
        [:aiur, :github, :resource_store, :sweep],
        fn _event, measurements, _metadata, _config -> send(test_pid, {:sweep, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      for index <- 1..12 do
        key = ResourceStore.key(:issue, "owner", "repo", index)
        :ok = ResourceStore.put_resource(key, body(index), source: :fetch, etag: "etag-#{index}")
      end

      assert Memory.stats().body_bytes > cap

      send(store, :sweep)
      _state = :sys.get_state(store)

      # Each body is a little over 100 KiB, so three fit under 400 KiB.
      assert %{entries: 12, bodies: 3, body_bytes: body_bytes} = Memory.stats()
      assert body_bytes <= cap
      assert_receive {:sweep, %{entries: 12, bodies: 3, body_bytes: ^body_bytes, shed: 9}}, 1_000
    end

    # Guards a future regression: this already holds, and it is what keeps a
    # shed `:issue_blocked_by` body from being read as "no blockers".
    test "a body shed by the sweep reads as a miss, never as empty data" do
      Application.put_env(:aiur, :github_resource_store_max_body_bytes, 150 * 1024)
      first = ResourceStore.key(:issue_blocked_by, "owner", "repo", 1)
      second = ResourceStore.key(:issue_blocked_by, "owner", "repo", 2)

      :ok =
        ResourceStore.put_resource(first, [%{"number" => 9, "body" => String.duplicate("x", @body_bytes)}],
          source: :fetch,
          etag: "etag-1"
        )

      :ok =
        ResourceStore.put_resource(second, [%{"number" => 8, "body" => String.duplicate("y", @body_bytes)}],
          source: :fetch,
          etag: "etag-2"
        )

      store = Process.whereis(ResourceStore)
      send(store, :sweep)
      _state = :sys.get_state(store)

      assert ResourceStore.fetch(first) == :miss
      assert ResourceStore.data(first) == nil
      assert ResourceStore.etag(first) == nil
      assert ResourceStore.change_validator(first) == "etag-1"
      assert {:ok, %{data: [%{"number" => 8}]}} = ResourceStore.fetch(second)
    end

    test "a checkpoint leaves no copy of the bodies on the store's heap" do
      dir = Aiur.TestSupport.tmp_root!("aiur-resource-store-memory")
      File.mkdir_p!(dir)
      path = Path.join(dir, "github_resources.json")
      Application.put_env(:aiur, :github_resource_store_path, path)
      :ok = Supervisor.terminate_child(Aiur.Supervisor, ResourceStore)
      {:ok, store} = Supervisor.restart_child(Aiur.Supervisor, ResourceStore)

      on_exit(fn ->
        Application.delete_env(:aiur, :github_resource_store_path)
        Supervisor.terminate_child(Aiur.Supervisor, ResourceStore)
        Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
        File.rm_rf(dir)
      end)

      # Short strings live on the process heap (a long one is a shared binary
      # that `:memory` does not count), so each body is ~100 KiB of heap and a
      # retained document or snapshot of these forty is several MiB.
      heap_body = fn index -> %{"items" => for(item <- 1..3000, do: "item-#{index}-#{item}")} end
      entries = for index <- 1..40, do: {{:issue, "owner", "repo", "#{index}"}, %{entry(index) | data: heap_body.(index)}}
      :ets.insert(ResourceStore.Table, entries)

      assert :ok = ResourceStore.flush(store)
      _state = :sys.get_state(store)

      assert {:memory, bytes} = Process.info(store, :memory)
      assert bytes < 1024 * 1024

      checkpoint = path |> File.read!() |> Jason.decode!()
      assert map_size(checkpoint["entries"]) == 40
      assert checkpoint["entries"]["issue|owner|repo|7"]["data"] == heap_body.(7)
    end
  end

  describe "the size report" do
    test "status reports the entries, bodies and bytes the store holds" do
      key = ResourceStore.key(:issue, "owner", "repo", 1)
      :ok = ResourceStore.put_resource(key, body(1), source: :fetch)
      ResourceStore.put_etag(ResourceStore.key(:issue, "owner", "repo", 2), "etag-2")

      assert %{entries: 2, bodies: 1, body_bytes: bytes, process_bytes: process_bytes} = Memory.stats()
      assert bytes == :erlang.external_size(body(1))
      assert process_bytes > 0

      assert capture_io(fn -> Memory.print_status() end) =~
               "GITHUB RESOURCES entries=2 bodies=1 body_bytes=0.1MiB/128.0MiB process="
    end

    test "a store that is not running is reported unavailable, never as empty" do
      assert Memory.stats(:no_such_resource_store_table) == :unavailable

      output = capture_io(fn -> Memory.print_status(:no_such_resource_store_table) end)
      assert output == "GITHUB RESOURCES unavailable (resource store is not running)\n"
    end

    test "aiur status prints the GITHUB RESOURCES line for the GitHub tracker only" do
      write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
      assert capture_io(fn -> AgentControlCLI.status() end) =~ "GITHUB RESOURCES entries="

      write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory")
      refute capture_io(fn -> AgentControlCLI.status() end) =~ "GITHUB RESOURCES"
    end
  end
end
