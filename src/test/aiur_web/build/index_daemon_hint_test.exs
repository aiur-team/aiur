defmodule AiurWeb.Build.IndexDaemonHintTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  alias AiurWeb.Build.{DataSource, Index, IndexSource}

  # A slow first index read must not hide the daemon state the index already observed (#4915).
  test "connected mount carries the last daemon reading while the first snapshot is still loading" do
    parent = self()
    name = __MODULE__.Index
    block = %{state: "live", heartbeat_at: 1_791_407_990_000, observed_at: 1_791_407_995_000}

    start_supervised!(
      {Index,
       name: name,
       subscribe: fn -> :ok end,
       read: fn _, _, _ -> receive(do: (:never -> nil)) end,
       read_timeout: 60_000,
       daemon_read: fn _ -> block end,
       daemon_timer: fn _, _, _ ->
         send(parent, :daemon_ready)
         make_ref()
       end}
    )

    receive_barrier(:daemon_ready)
    Application.put_env(:aiur, :build_data_source, {IndexSource, [server: name, index_subscribe: fn -> :ok end]})
    before_mount = System.os_time(:millisecond)
    {:ok, view, _} = live(build_conn(), "/build")
    after_mount = System.os_time(:millisecond)
    [hint] = view |> render() |> Floki.parse_document!() |> Floki.attribute("#build-root[data-build-state=loading]", "data-daemon")
    assert %{"daemon" => %{"state" => "live", "heartbeat_at" => 1_791_407_990_000, "observed_at" => 1_791_407_995_000}, "now" => now} = Jason.decode!(hint)
    assert before_mount <= now and now <= after_mount
  end

  test "a source without a daemon reading leaves the mount hint empty" do
    assert DataSource.last_daemon({ProtocolCase.Spy, []}, []) == nil
    assert IndexSource.daemon(server: __MODULE__.Missing) == nil
  end
end
