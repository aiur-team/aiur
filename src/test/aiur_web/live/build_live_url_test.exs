defmodule AiurWeb.BuildLiveURLTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  alias AiurWeb.Build.URLState

  test "initial container has URL state and mount does not push" do
    {:ok, view, html} = live(build_conn(), "/build?view=gantt")
    [json] = html |> Floki.parse_document!() |> Floki.attribute("#build-root", "data-url-state")
    assert Jason.decode!(json) == URLState.parse(%{"view" => "gantt"}) |> Jason.encode!() |> Jason.decode!()
    refute_url_push(view)
  end

  test "noncanonical first loads redirect, including malformed escapes and nested values" do
    for {query, target} <- [{"view=list&zoom=2", "/build?view=list"}, {"epic=%zz", "/build"}, {"epic[]=x", "/build"}, {"view=list&view=gantt", "/build?view=gantt"}] do
      assert build_conn() |> get("/build?" <> query) |> redirected_to() == target
    end
  end

  test "invalid UTF-8 returns 400 (future Plug regression guard)" do
    assert_error_sent(400, fn -> get(build_conn(), "/build?epic=%ff") end)
  end

  test "params canonicalize, map legacy presets and let explicit home groups win" do
    {:ok, view, _} = live(build_conn(), "/build")
    render_patch(view, "/build?span=4&view=list&zoom=2")
    assert_patch(view, "/build?view=list")
    assert_push_event(view, "build:url", %{state: %{view: "list", span: 1}})
    render_patch(view, "/build?v=1&scope=unfinished&conditions=active")
    assert_patch(view, "/build?astate=active")
    assert_push_event(view, "build:url", %{state: %{astate: ["active"]}})
    render_patch(view, "/build?conditions=alert&astate=paused")
    assert_patch(view, "/build?astate=paused")
    assert_push_event(view, "build:url", %{state: %{astate: ["paused"]}})
  end

  test "hook patches with replacement and no echo or redundant patch" do
    {:ok, view, _} = live(build_conn(), "/build")
    render_hook(view, "build:url", %{"view" => "gantt", "span" => "7"})
    %{proxy: {ref, topic, _}} = view
    assert_received {^ref, {:patch, ^topic, %{to: "/build?view=gantt&span=7", kind: :replace}}}
    refute_url_push(view)
    render_hook(view, "build:url", %{"view" => "gantt", "span" => "7"})
    refute_url_patch(view)
    refute_url_push(view)
  end

  test "hook retains absent ticket and clears explicit empty ticket" do
    {:ok, view, _} = live(build_conn(), "/build?ticket=12")
    render_hook(view, "build:url", %{"view" => "list"})
    assert_patch(view, "/build?view=list&ticket=12")
    render_hook(view, "build:url", %{"view" => "list", "ticket" => ""})
    assert_patch(view, "/build?view=list")
    render_hook(view, "build:url", %{})
    assert_patch(view, "/build")
    refute_url_push(view)
  end

  test "hook pushes corrections for rewritten inputs and never maps legacy payloads" do
    {:ok, view, _} = live(build_conn(), "/build")

    for params <- [%{"astate" => "bogus"}, %{"unknown" => "x"}, %{"conditions" => "alert"}] do
      render_hook(view, "build:url", params)
      assert_push_event(view, "build:url", %{state: %{astate: [], tstate: []}})
      refute_url_patch(view)
    end

    render_hook(view, "build:url", %{"span" => "07", "astate" => "active,active"})
    assert_patch(view, "/build?span=7&astate=active")
    assert_push_event(view, "build:url", %{state: %{span: 7, astate: ["active"]}})
    refute_url_push(view)
  end

  test "back and forward push restored state and defaults" do
    {:ok, view, _} = live(build_conn(), "/build")
    render_patch(view, "/build?view=list&epic=bugs")
    assert_push_event(view, "build:url", %{state: %{view: "list", epic: ["bugs"]}})
    render_patch(view, "/build")
    assert_push_event(view, "build:url", %{state: %{view: "graph", epic: []}})
    render_patch(view, "/build")
    refute_url_push(view)
  end

  defp refute_url_patch(view) do
    render(view)
    %{proxy: {ref, topic, _}} = view
    refute_received {^ref, {:patch, ^topic, _}}
  end

  defp refute_url_push(view) do
    render(view)
    %{proxy: {ref, _topic, _}} = view
    refute_received {^ref, {:push_event, "build:url", _}}
  end
end
