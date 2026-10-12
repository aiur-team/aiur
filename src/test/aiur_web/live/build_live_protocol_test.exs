defmodule AiurWeb.BuildLiveProtocolTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase

  test "resync returns mount epoch and reuses the first read only" do
    {:ok, view, _} = live(build_conn(), "/build")
    render_async(view)
    assert_received :subscribed
    assert_received {:read, [time_zone: "Etc/UTC", financial: {:ok, %AiurWeb.FinancialDataAccess.Context{}}]}
    render_hook(view, "build-resync", %{})
    assert_reply(view, reply)
    assert reply["v"] == 1
    assert reply["kind"] == "snapshot"
    assert reply["generation"] == 0
    assert reply["epoch"] == :sys.get_state(view.pid).socket.assigns.build_epoch
    assert length(reply["sections"]["now"]) == 8
    refute_received {:read, _}
    row = hd(data()["sections"]["now"])
    send(view.pid, {:build_changes, change(row)})
    render(view)
    render_hook(view, "build-resync", %{})
    assert_received {:read, _}
    assert_reply(view, updated)
    assert updated["generation"] == 1
  end

  test "each connected process has a different epoch" do
    {:ok, a, _} = live(build_conn(), "/build")
    {:ok, b, _} = live(build_conn(), "/build")
    render_async(a)
    render_async(b)
    render_hook(a, "build-resync", %{})
    render_hook(b, "build-resync", %{})
    assert_reply(a, one)
    assert_reply(b, two)
    refute one["epoch"] == two["epoch"]
    assert byte_size(one["epoch"]) == 16
  end

  test "locked snapshot sends only access copy and read-only truth" do
    source(ignore_financial: true)
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, false)
    {:ok, view, _} = live(build_conn(), "/build")
    render_async(view)
    revoke_access()
    render_hook(view, "build-resync", %{})
    assert_reply(view, reply)
    assert reply["writable"] == false
    expected = AiurWeb.FinancialDataAccess.locked_capability() |> Map.delete(:version) |> Payload.scrub()
    assert reply["usage"] == expected
    assert Enum.sort(Map.keys(reply["usage"])) == ~w(accessible_name authentication_path reason state)
  end

  test "broadcast diffs advance once and stale index changes never advance" do
    {:ok, view, _} = live(build_conn(), "/build")
    render_async(view)
    row = hd(data()["sections"]["now"])
    Phoenix.PubSub.broadcast(Aiur.PubSub, "build-home:fixture", {:build_changes, change(row, 5)})
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.build_generation == 0
    %{proxy: {ref, _, _}} = view
    refute_received {^ref, {:push_event, "build-diff", _}}

    for {index, generation} <- [{7, 1}, {8, 2}] do
      Phoenix.PubSub.broadcast(Aiur.PubSub, "build-home:fixture", {:build_changes, change(row, index)})
      render(view)
      assert_push_event(view, "build-diff", %{"kind" => "diff", "generation" => ^generation, "upsert" => [^row], "epoch" => epoch})
      assert epoch == :sys.get_state(view.pid).socket.assigns.build_epoch
    end
  end

  test "index restart creates a gap and clears private index generation" do
    {:ok, view, _} = live(build_conn(), "/build")
    render_async(view)
    row = hd(data()["sections"]["now"])
    for index <- 7..9, do: send(view.pid, {:build_changes, change(row, index)})
    render(view)
    send(view.pid, {:build_changes, %{resync: true, index_generation: 1}})
    render(view)
    assert_push_event(view, "build-diff", %{"generation" => 5, "upsert" => [], "remove" => [], "set" => %{}})
    assert :sys.get_state(view.pid).socket.assigns.build_index_generation == nil
    render_hook(view, "build-resync", %{})
    assert_reply(view, reply)
    assert reply["generation"] == 5
  end

  test "locked socket strips usage but retains the row upsert" do
    {:ok, view, _} = live(build_conn(), "/build")
    render_async(view)
    revoke_access()
    row = hd(data()["sections"]["now"])
    changes = %{change(row) | set: %{usage: data()["usage"]}}
    send(view.pid, {:build_changes, changes})
    render(view)
    assert_push_event(view, "build-diff", %{"upsert" => [^row], "set" => set})
    refute Map.has_key?(set, "usage")
  end

  test "paging uses the mount zone, accepts days, and expands the diff window" do
    conn = put_connect_params(build_conn(), %{"time_zone" => "America/Los_Angeles"})
    {:ok, view, _} = live(conn, "/build")
    render_async(view)
    render_hook(view, "build-resync", %{})
    assert_reply(view, initial)
    from = initial["history"]["from"]
    render_hook(view, "load-earlier", %{"before" => from})
    assert_reply(view, one)
    assert one["kind"] == "earlier"
    assert one["history"]["from"] < from
    assert_received {:earlier, ^from, "America/Los_Angeles", 1}
    render_hook(view, "load-earlier", %{"before" => one["history"]["from"], "days" => 2})
    assert_reply(view, two)
    assert_received {:earlier, _, "America/Los_Angeles", 2}
    dates = Enum.map(two["rows"], &(&1["end"] |> DateTime.from_unix!(:millisecond) |> DateTime.shift_zone!("America/Los_Angeles", Tz.TimeZoneDatabase) |> DateTime.to_date())) |> Enum.uniq()
    assert length(dates) == 2
    older = Enum.min_by(data()["sections"]["hist"], & &1["end"])
    send(view.pid, {:build_changes, change(older)})
    render(view)
    assert_push_event(view, "build-diff", %{"upsert" => []})
    newer = hd(two["rows"])
    send(view.pid, {:build_changes, change(newer, 8)})
    render(view)
    assert_push_event(view, "build-diff", %{"upsert" => [^newer]})
    render_hook(view, "build-resync", %{})
    assert_reply(view, reset)
    assert reset["history"]["from"] == from
  end

  test "invalid paging parameters reply without crashing or changing history" do
    {:ok, view, _} = live(build_conn(), "/build")
    render_async(view)
    original = :sys.get_state(view.pid).socket.assigns.build_history

    for params <- [%{}, %{"before" => "x"}, %{"before" => -1}, %{"before" => System.system_time(:millisecond) + 172_800_000}, %{"before" => 1, "days" => 0}, %{"before" => 1, "days" => 32}] do
      render_hook(view, "load-earlier", params)
      assert_reply(view, %{"kind" => "error", "reason" => "invalid_params"})
      assert Process.alive?(view.pid)
      assert :sys.get_state(view.pid).socket.assigns.build_history == original
    end
  end
end
