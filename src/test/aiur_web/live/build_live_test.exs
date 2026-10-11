defmodule AiurWeb.BuildLiveTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest
  alias AiurWeb.{BuildLive, Endpoint}
  @endpoint Endpoint

  defmodule Spy do
    @behaviour AiurWeb.Build.DataSource
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
    assert Floki.find(root, ".bd-loading") |> Floki.text() |> String.trim() == "Loading build timeline…"
  end

  test "dead render does not call the source; connected mount loads once" do
    assert build_conn() |> get("/build") |> html_response(200) =~ "Loading build timeline…"
    refute_receive :subscribe, 100
    refute_receive {:snapshot, _}, 100
    {:ok, view, _} = live(build_conn(), "/build")
    assert_receive :subscribe, 1_000
    assert_receive {:snapshot, _}, 1_000
    assert render_async(view) =~ ~s(data-build-state="ready")
    refute has_element?(view, "#build-root[data-build-reason]")
    assert :sys.get_state(view.pid).socket.assigns.build_snapshot == %{"meta" => %{"now" => 1_791_408_000_000}, "writable" => true}
    refute_receive {:snapshot, _}, 100
  end

  test "source errors render unavailable with a cause-neutral tag" do
    for {error, tag} <- [{:boom, "unknown"}, {:not_wired, "not_wired"}, {:timeout, "timeout"}] do
      source(result: {:error, error})
      {:ok, view, _} = live(build_conn(), "/build")
      render_async(view)
      assert has_element?(view, ~s(#build-root[data-build-state=unavailable][data-build-reason="#{tag}"]))
    end
  end

  test "source crash renders unavailable" do
    source(result: :crash)
    {:ok, view, _} = live(build_conn(), "/build")
    render_async(view)
    assert has_element?(view, "#build-root[data-build-state=unavailable][data-build-reason=crashed]")
  end

  test "timeout cancels the snapshot and ignores cancellation and late results" do
    source(result: :hold)
    {:ok, view, _} = live(build_conn(), "/build")
    assert_receive {:snapshot, task}, 1_000
    monitor = Process.monitor(task)
    send(view.pid, :build_snapshot_timeout)
    render_async(view)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}, 1_000
    assert has_element?(view, "#build-root[data-build-state=unavailable][data-build-reason=timeout]")
    socket = %Phoenix.LiveView.Socket{assigns: %{build_state: {:unavailable, "timeout"}}}
    assert {:noreply, ^socket} = BuildLive.handle_async(:build_snapshot, {:ok, {:ok, %{}}}, socket)
    assert {:noreply, ^socket} = BuildLive.handle_async(:build_snapshot, {:exit, :late}, socket)
  end

  test "a timeout after ready is ignored" do
    {:ok, view, _} = live(build_conn(), "/build")
    render_async(view)
    send(view.pid, :build_snapshot_timeout)
    assert render(view) =~ ~s(data-build-state="ready")
  end

  test "default source is not wired" do
    Application.delete_env(:aiur, :build_data_source)
    {:ok, view, _} = live(build_conn(), "/build")
    render_async(view)
    assert has_element?(view, "#build-root[data-build-state=unavailable][data-build-reason=not_wired]")
  end

  test "subscription failure still loads the snapshot" do
    source(subscription: {:error, :boom})
    {:ok, view, _} = live(build_conn(), "/build")
    assert render_async(view) =~ ~s(data-build-state="ready")
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
