defmodule AiurWeb.BuildLiveTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  alias Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.TestSupport.LiveViewAsync
  alias AiurWeb.Build.{DataSource, Index, IndexSource}
  alias AiurWeb.{BuildLive, Endpoint}
  @endpoint Endpoint

  defmodule Spy do
    @behaviour AiurWeb.Build.DataSource
    alias Aiur.TestSupport.BuildHome.FixtureSource
    @impl true
    def ticket(id, opts), do: FixtureSource.ticket(id, opts)

    @impl true
    def subscribe(opts) do
      send(opts[:test_pid], :subscribe)
      Keyword.get(opts, :subscription, :ok)
    end

    @impl true
    def earlier(_before, _zone, _opts), do: {:error, :not_wired}

    @impl true
    def snapshot(opts) do
      send(opts[:test_pid], {:snapshot, self()})

      case Keyword.get(opts, :result, {:ok, %{"meta" => %{"now" => 1_791_408_000_000}}}) do
        :crash -> raise "fixture crash"
        :hold -> receive do: (:release -> {:ok, %{}})
        result -> result
      end
    end

    @impl true
    def last_agents(opts), do: Keyword.get(opts, :last_agents, {:error, :unavailable})
  end

  setup do
    previous = Application.get_env(:aiur, :build_data_source)
    config = Application.get_env(:aiur, Endpoint)
    Application.put_env(:aiur, Endpoint, Keyword.merge(config || [], server: false, dashboard_auth_required: false, secret_key_base: String.duplicate("s", 64)))
    source()
    Aiur.TestSupport.start_owned_endpoint!()

    on_exit(fn ->
      restore(:build_data_source, previous)
      restore(Endpoint, config)
    end)

    :ok
  end

  test "dead render is the design skeleton" do
    html = build_conn() |> get("/build") |> html_response(200) |> Floki.parse_document!()
    root = Floki.find(html, "#build-root.bd-root[phx-hook=BuildHome][phx-update=ignore][data-build-state=loading]")
    assert length(root) == 1
    [{_, _, children}] = root
    elements = Enum.filter(children, &is_tuple/1)

    assert Enum.map(elements, fn {tag, attrs, _} -> {tag, attrs} end) == [
             {"div", [{"id", "bd-usage"}]},
             {"div", [{"id", "bd-offline"}]},
             {"div", [{"id", "bd-fh"}]},
             {"div", [{"id", "bd-partial"}, {"class", "bd-partial"}, {"aria-live", "polite"}]},
             {"div", [{"class", "bd-toolbar"}]},
             {"div", [{"class", "bd-vpw"}]},
             {"div", [{"class", "bd-status"}, {"id", "bd-status"}]}
           ]

    assert Floki.attribute(root, ".bd-toolbar > div", "id") == ~w(bd-tools-l bd-filters bd-tools)
    assert Floki.attribute(root, ".bd-toolbar > div", "class") == ~w(bd-bar-l bd-filters bd-bar-r)
    assert Floki.attribute(root, ".bd-vpw > div", "id") == ~w(bd-vp bd-sb bd-tree)
    assert length(Floki.find(root, "#bd-sb > i")) == 1
    assert length(Floki.find(root, "#bd-tree.bd-tree[hidden]")) == 1
    assert length(Floki.find(root, "#bd-vp > .bd-lanes > .bd-skel-lanes > i")) == 4
    assert Floki.attribute(root, ".bd-skel-lanes > i", "style") == List.duplicate("background: var(--surface-3)", 4)
    assert length(Floki.find(root, ".bd-skel-lanes > i.bd-skel-i:first-child")) == 1
    assert length(Floki.find(root, "#bd-vp > .bd-skel > i")) == 16
    assert length(Floki.find(root, "#bd-vp > .bd-loading > span.bd-spin")) == 1
    assert Floki.attribute(root, ".bd-loading", "role") == ["status"]
    assert Floki.find(root, ".bd-loading") |> Floki.text() |> String.trim() == "Loading build timeline…"
  end

  test "dead render does not call the source; connected mount loads once" do
    assert build_conn() |> get("/build") |> html_response(200) =~ "Loading build timeline…"
    refute_receive :subscribe, 100
    refute_receive {:snapshot, _}, 100
    {:ok, view, _} = live(build_conn(), "/build")
    assert_receive :subscribe, 1_000
    assert_receive {:snapshot, _}, 1_000
    assert LiveViewAsync.render_when_complete(view) =~ ~s(data-build-state="ready")
    refute has_element?(view, "#build-root[data-build-reason]")
    assert :sys.get_state(view.pid).socket.assigns.build_snapshot == %{"meta" => %{"now" => 1_791_408_000_000}, "writable" => true}
    refute_receive {:snapshot, _}, 100
  end

  test "source errors render unavailable with a cause-neutral tag" do
    for {error, tag} <- [
          {:boom, "unknown"},
          {:not_wired, "not_wired"},
          {:timeout, "timeout"},
          {:epic_config_unavailable, "epic_config_unavailable"},
          {:settings_loading, "settings_loading"},
          {:index_not_running, "index_not_running"},
          {:read_failed, "read_failed"}
        ] do
      source(result: {:error, error})
      {:ok, view, _} = live(build_conn(), "/build")
      LiveViewAsync.render_when_complete(view)
      assert has_element?(view, ~s(#build-root[data-build-state=unavailable][data-build-reason="#{tag}"]))
    end
  end

  test "source crash renders unavailable" do
    source(result: :crash)
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    assert has_element?(view, "#build-root[data-build-state=unavailable][data-build-reason=crashed]")
  end

  test "timeout cancels the snapshot and ignores cancellation and late results" do
    source(result: :hold)
    {:ok, view, _} = live(build_conn(), "/build")
    assert_receive {:snapshot, task}, 1_000
    monitor = Process.monitor(task)
    send(view.pid, :build_snapshot_timeout)
    LiveViewAsync.render_when_complete(view)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}, 1_000
    assert has_element?(view, "#build-root[data-build-state=unavailable][data-build-reason=timeout]")
    socket = %Phoenix.LiveView.Socket{assigns: %{build_state: {:unavailable, "timeout"}}}
    assert {:noreply, ^socket} = BuildLive.handle_async(:build_snapshot, {:ok, {:ok, %{}}}, socket)
    assert {:noreply, ^socket} = BuildLive.handle_async(:build_snapshot, {:exit, :late}, socket)
  end

  test "first snapshot timeout renders retained agent rows with their observation age" do
    name = __MODULE__.FirstLoadTimeout
    observed_at = IndexParts.now()
    observed_now = fn -> observed_at end
    parts = IndexParts.parts() |> put_in([:now, :rows], %{"11" => IndexParts.now_row(11)})

    start_supervised!(
      {Index,
       name: name,
       subscribe: fn -> :ok end,
       read: fn _, _, _ -> parts end,
       daemon_read: fn _ -> %{state: "live", heartbeat_at: observed_at, observed_at: observed_at} end,
       daemon_timer: fn _, _, _ -> make_ref() end,
       clock: observed_now}
    )

    source(server: name, index_subscribe: fn -> :ok end)
    send(name, :flush)
    assert {:ok, %{index_generation: generation}} = Index.window(name, "Etc/UTC")
    assert generation > 0
    assert {:ok, %{sections: %{now: [_]}, observed_at: ^observed_at} = retained} = IndexSource.last_agents(server: name, index_subscribe: fn -> :ok end)
    source(result: :hold, last_agents: {:ok, retained}, server: name, index_subscribe: fn -> :ok end)
    {:ok, view, _} = live(build_conn(), "/build")
    assert_receive {:snapshot, task}, 1_000
    monitor = Process.monitor(task)

    send(view.pid, :build_snapshot_timeout)
    LiveViewAsync.render_when_complete(view)

    assert_receive {:DOWN, ^monitor, :process, ^task, _}, 1_000
    assert has_element?(view, "#build-root[data-build-state=ready]")
    assert Enum.map(:sys.get_state(view.pid).socket.assigns.build_snapshot["sections"]["now"], & &1["id"]) == ["11"], inspect(:sys.get_state(view.pid).socket.assigns.build_snapshot)
    assert :sys.get_state(view.pid).socket.assigns.build_snapshot["sources"]["agents"]["state"] == "stale"
    assert :sys.get_state(view.pid).socket.assigns.build_snapshot["sources"]["agents"]["observed_at"] == observed_at
  end

  test "a timeout after ready is ignored" do
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    send(view.pid, :build_snapshot_timeout)
    assert render(view) =~ ~s(data-build-state="ready")
  end

  test "default source reads the supervised ticket index" do
    Application.delete_env(:aiur, :build_data_source)
    assert DataSource.source() == IndexSource

    pid =
      start_supervised!(
        {Index, name: nil, subscribe: fn -> :ok end, read: fn _, _, _ -> IndexParts.parts([IndexParts.row(7)]) end, daemon_read: fn _ -> %{state: "unknown", heartbeat_at: nil, observed_at: nil} end}
      )

    assert {:ok, snapshot} = DataSource.call(DataSource.source(), :snapshot, [[server: pid, financial: :locked]])
    assert Enum.map(snapshot.sections.hist, & &1.num) == [7]
  end

  test "subscription failure still loads the snapshot" do
    source(subscription: {:error, :boom})
    {:ok, view, _} = live(build_conn(), "/build")
    assert LiveViewAsync.render_when_complete(view) =~ ~s(data-build-state="ready")
  end

  test "modal frame is an ignored sibling of the shell" do
    html = build_conn() |> get("/build") |> html_response(200) |> Floki.parse_document!()
    assert Floki.find(html, ".dashboard-shell #tk-backdrop") == []
    assert length(Floki.find(html, "#tk-backdrop.tk-backdrop[phx-update=ignore] > #tk-modal.tk-modal[role=dialog][aria-modal=true][aria-label='Ticket context']")) == 1
    assert length(Floki.find(html, "#tk-modal > header#tk-head.tk-head")) == 1
    assert length(Floki.find(html, "#tk-modal > div#tk-body.tk-body")) == 1
  end

  test "/build requires dashboard auth" do
    Application.put_env(:aiur, Endpoint, Keyword.put(Application.get_env(:aiur, Endpoint), :dashboard_auth_required, true))
    unauthorized = Phoenix.ConnTest.build_conn() |> get("/build")
    assert unauthorized.status == 401
    authorized = build_conn() |> get("/build")
    assert authorized.status == 200
  end

  defp build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  end

  defp source(opts \\ []), do: Application.put_env(:aiur, :build_data_source, {Spy, [test_pid: self()] ++ opts})
  defp restore(key, nil), do: Application.delete_env(:aiur, key)
  defp restore(key, value), do: Application.put_env(:aiur, key, value)
end
