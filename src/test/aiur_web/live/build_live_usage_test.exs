defmodule AiurWeb.BuildLiveUsageTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  alias Aiur.ProviderMeterRefresh
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias Aiur.TestSupport.LiveViewAsync
  alias AiurWeb.Build.{Read, Usage}
  alias AiurWeb.{Endpoint, FinancialData, FinancialDataAccess}

  defmodule UsageSpy do
    def read(_financial, opts) do
      send(Endpoint.config(:build_usage_test_pid), {:usage_read, opts})
      Endpoint.config(:build_usage_test_block)
    end
  end

  defmodule RevokingSource do
    @behaviour AiurWeb.Build.DataSource
    @impl true
    def subscribe(opts) do
      :ok = Usage.subscribe(opts[:financial])
      FixtureSource.subscribe(opts)
    end

    @impl true
    def snapshot(opts) do
      result = FixtureSource.snapshot(opts)
      if Endpoint.config(:build_usage_revoke_on_snapshot), do: ProtocolCase.revoke_access()
      result
    end

    @impl true
    def earlier(before, zone, opts), do: FixtureSource.earlier(before, zone, opts)
  end

  setup do
    if is_nil(Process.whereis(ProviderMeterRefresh)), do: start_supervised!({ProviderMeterRefresh, observer: fn _target -> :ok end})
    Phoenix.Config.put(Endpoint, :build_usage_revoke_on_snapshot, false)
    Phoenix.Config.put(Endpoint, :build_usage_source, UsageSpy)
    Phoenix.Config.put(Endpoint, :build_usage_test_pid, self())
    Phoenix.Config.put(Endpoint, :build_usage_test_block, data()["usage"])
    owner = self()
    Phoenix.Config.put(Endpoint, :build_usage_flush_timer, fn pid, event, ms -> send(owner, {:flush_timer, pid, event, ms}) end)
    :ok
  end

  test "watch hook registers and withdraws the live process and remains hidden" do
    {:ok, view, html} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    assert html =~ ~s(id="usage-watch" phx-hook="UsageWatch" hidden)
    render_hook(view, "usage-watch-start", %{})
    assert Map.has_key?(:sys.get_state(ProviderMeterRefresh).watchers, view.pid)
    render_hook(view, "usage-watch-stop", %{})
    refute Map.has_key?(:sys.get_state(ProviderMeterRefresh).watchers, view.pid)
  end

  test "burst coalesces the newest update into one read and one changed usage diff" do
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    changed = put_in(data(), ["usage", "providers", Access.at(0), "name"], "Updated provider")["usage"]
    Phoenix.Config.put(Endpoint, :build_usage_test_block, changed)
    for id <- 1..3, do: send(view.pid, {FinancialData, :updated, id})
    render(view)
    assert_received {:flush_timer, pid, :build_usage_flush, 250}
    assert pid == view.pid
    refute_received {:flush_timer, _, _, _}
    refute_received {:usage_read, _}
    send(view.pid, :build_usage_flush)
    render(view)
    assert_received {:usage_read, [reload: {FinancialData, :updated, 3}]}
    refute_received {:usage_read, _}
    assert_push_event(view, "build-diff", %{"generation" => 1, "set" => %{"usage" => ^changed}})
    refute_diff(view)
  end

  test "unchanged ticks compare against both snapshot and resync usage" do
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    assert assigns(view).build_usage_last == data()["usage"]
    send(view.pid, :build_usage_github_tick)
    render(view)
    assert_received {:usage_read, []}
    refute_diff(view)
    render_hook(view, "build-resync", %{})
    assert_reply(view, reply)
    assert assigns(view).build_usage_last == reply["usage"]
    send(view.pid, :build_usage_elevenlabs_tick)
    render(view)
    assert_received {:usage_read, []}
    refute_diff(view)
  end

  test "revoked flush creates a resync gap, clears usage and cancels ticks" do
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    refs = assigns(view).build_usage_timers
    send(view.pid, {FinancialData, :updated, 1})
    render(view)
    revoke_access()
    send(view.pid, :build_usage_flush)
    render(view)
    assert_push_event(view, "build-diff", %{"generation" => 2, "set" => %{}})
    assert assigns(view).build_usage_last == nil
    assert assigns(view).build_usage_timers == nil
    for {_event, ref} <- refs, do: assert(Process.read_timer(ref) == false)
    refute_received {:usage_read, _}
    render_hook(view, "build-resync", %{})
    assert_reply(view, reply)
    assert reply["usage"] == Read.locked_usage()
    send(view.pid, :build_usage_github_tick)
    render(view)
    assert assigns(view).build_usage_timers == nil
    refute_diff(view)
    refute_received {:usage_read, _}
  end

  test "locked connected mount neither schedules ticks nor reads on late messages" do
    source(ignore_financial: true)
    conn = get(build_conn(), "/build")
    revoke_access()
    {:ok, view, _} = live(conn)
    LiveViewAsync.render_when_complete(view)
    assert assigns(view).build_usage_timers == nil
    assert assigns(view).build_usage_last == Read.locked_usage()
    assert assigns(view).build_snapshot["usage"] == Read.locked_usage()
    render_hook(view, "usage-watch-start", %{})
    refute Map.has_key?(:sys.get_state(ProviderMeterRefresh).watchers, view.pid)
    send(view.pid, :build_usage_github_tick)
    send(view.pid, {FinancialData, :updated, 1})
    send(view.pid, :build_usage_flush)
    render(view)
    refute_received {:usage_read, _}
    refute_received {:flush_timer, _, _, _}
    assert assigns(view).build_usage_timers == nil
    refute_diff(view)
  end

  test "real financial facade broadcast reaches the usage flush subscription" do
    Application.put_env(:aiur, :build_data_source, {RevokingSource, dataset: "live"})
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    context = view.pid |> :sys.get_state() |> Map.fetch!(:socket) |> FinancialDataAccess.context()
    {:ok, identity} = FinancialDataAccess.identity(context)
    FinancialData.broadcast_update()
    render(view)
    assert_received {:flush_timer, pid, :build_usage_flush, 250}
    assert pid == view.pid
    send(view.pid, :build_usage_flush)
    render(view)
    assert_received {:usage_read, [reload: {FinancialData, :updated, ^identity}]}
  end

  test "resync rechecks access after a source read revokes the configuration" do
    Application.put_env(:aiur, :build_data_source, {RevokingSource, dataset: "live"})
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    render_hook(view, "build-resync", %{})
    assert_reply(view, first)
    assert first["usage"]["state"] == "authorized"
    Phoenix.Config.put(Endpoint, :build_usage_revoke_on_snapshot, true)
    render_hook(view, "build-resync", %{})
    assert_reply(view, revoked)
    assert revoked["usage"] == Read.locked_usage()
    assert assigns(view).build_usage_last == Read.locked_usage()
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
  defp refute_diff(%{proxy: {ref, _, _}}), do: refute_received({^ref, {:push_event, "build-diff", _}})
end
