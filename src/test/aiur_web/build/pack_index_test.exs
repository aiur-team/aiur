defmodule AiurWeb.Build.PackIndexTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport, only: [receive_barrier: 1]
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.BuildOrder.Index, as: Core
  alias AiurWeb.Build.{Index, IndexReader, IndexSource}

  test "filing removes provisional row and marks the real row in one diff" do
    {:ok, old} = parts([row(9)]) |> read_packs(pack(nil)) |> assemble()
    {:ok, new} = parts([row(9), row(1234)]) |> read_packs(pack(1234)) |> assemble()
    assert Map.has_key?(old.all, "pack:demo/A")
    refute Map.has_key?(new.all, "pack:demo/A")
    assert %{remove: ["pack:demo/A"], upsert: upsert} = Core.diff(old, new)
    assert Enum.find(upsert, &(&1.id == "1234")).was == "pack:demo/A"
  end

  test "queue failure leaves pack rows visible and appends filed dependency children" do
    p = parts([row(9)]) |> Map.put(:planned, {:error, :boom}) |> read_packs(pack(nil))
    assert {:ok, index} = assemble(p)
    assert index.sources.queue.state == "unavailable"
    assert index.sources.packs.state == "ok"
    assert index.all["pack:demo/A"].wave == 1
    assert index.all["9"].children == ["pack:demo/A"]
    assert index.all["pack:demo/A"].dep_states == %{"9" => "cleared"}
  end

  test "every flush rereads packs even when no pack signal arrived" do
    before = read_packs(parts([row(9), row(1234)]), pack(nil))
    after_read = IndexReader.read(MapSet.new(), before, packs_opts: [loader: fn -> pack(1234) end])
    assert {:ok, index} = assemble(after_read)
    refute Map.has_key?(index.all, "pack:demo/A")
    assert index.all["1234"].was == "pack:demo/A"
  end

  test "by-id reads follow filing aliases outside the loaded window" do
    p = read_packs(parts([row(9), row(1234)]), pack(1234))

    server =
      start_supervised!({Index, name: nil, subscribe: fn -> :ok end, read: fn _, _, _ -> p end, clock: &now/0, daemon_read: fn _ -> %{state: "unknown", heartbeat_at: nil, observed_at: now()} end})

    assert {:ok, _window} = Index.window(server, "Etc/UTC")
    assert {:ok, %{id: "1234", was: "pack:demo/A"}} = IndexSource.ticket("pack:demo/A", server: server)
    assert {:error, :not_found} = IndexSource.ticket("pack:demo/MISSING", server: server)
  end

  test "daemon tick rereads a rewritten pack without a publisher signal" do
    parent = self()
    result = start_supervised!({Agent, fn -> pack(nil) end})
    p = parts([row(9), row(1234)])

    server =
      start_supervised!(
        {Index,
         name: nil,
         subscribe: fn -> :ok end,
         read: fn _, _, _ -> read_packs(p, Agent.get(result, & &1)) end,
         broadcast: fn change -> send(parent, {:pack_change, change}) end,
         timer: fn pid, message, _ms -> Process.send_after(pid, message, 0) end,
         clock: &now/0,
         daemon_timer: fn _, _, _ ->
           send(parent, :daemon_observed)
           make_ref()
         end,
         daemon_read: fn _ -> %{state: "unknown", heartbeat_at: nil, observed_at: now()} end}
      )

    assert {:ok, initial} = Index.window(server, "Etc/UTC")
    assert Enum.any?(initial.sections.plan, &(&1.id == "pack:demo/A"))
    receive_barrier(:daemon_observed)
    Agent.update(result, fn _ -> pack(1234) end)
    send(server, :daemon_tick)
    receive_barrier({:pack_change, %{remove: ["pack:demo/A"], upsert: upserts}})
    assert Enum.find(upserts, &(&1.id == "1234")).was == "pack:demo/A"
    assert {:ok, %{id: "1234"}} = IndexSource.ticket("pack:demo/A", server: server)
  end

  test "failed and missing packs parts remain unavailable rather than healthy or disabled" do
    for failure <- [{:error, :read_failed}, nil, fn _index -> raise "pack read failed" end] do
      assert {:ok, index} = parts([row(9)]) |> Map.put(:packs, failure) |> assemble()
      assert index.sources.packs == %{state: "unavailable", observed_at: now(), reason: "planning packs could not be read"}
      assert Map.keys(index.all) == ["9"]
    end
  end

  test "pack loader failure is unavailable through the index reader" do
    for loader <- [fn -> {:error, :unreadable} end, fn -> raise "bad pack" end] do
      read = IndexReader.read(MapSet.new(), parts([row(9)]), packs_opts: [loader: loader], clock: &now/0)
      assert {:ok, index} = assemble(read)
      assert index.sources.packs == %{state: "unavailable", observed_at: now(), reason: "planning packs could not be read"}
      assert Map.keys(index.all) == ["9"]
    end
  end

  test "pack reader consumes the already assembled filed rows once" do
    parent = self()

    reader = fn context ->
      send(parent, {:assembled_rows, Map.keys(context.all), Map.keys(context.epics)})
      %{rows: [], aliases: %{}, source: %{state: "disabled", observed_at: now(), reason: "no_pack_configured"}}
    end

    assert {:ok, index} = parts([row(9)]) |> Map.put(:packs, reader) |> assemble()
    receive_barrier({:assembled_rows, ["9"], epics})
    assert Enum.sort(epics) == Enum.sort(Map.keys(index.epics))
    refute_received {:assembled_rows, _, _}
    assert index.sources.packs.state == "disabled"
  end

  defp read_packs(parts, result), do: IndexReader.read(MapSet.new(), parts, packs_opts: [loader: fn -> result end], clock: &now/0)

  defp pack(number) do
    %{
      configured: 1,
      failed: [],
      packs: [
        %{
          completed: false,
          build_order_id: "acme/widgets:demo",
          build_order_id_explicit?: true,
          path: "/private/demo.json",
          source: :configured,
          tickets: [
            %{id: "A", number: number, title: "Planned", phase: 0, lane: "bugs", complexity: 3, depends_on: ["D"]},
            %{id: "D", number: 9, title: "Done", phase: 0, lane: "bugs", complexity: 1, depends_on: []}
          ]
        }
      ]
    }
  end
end
