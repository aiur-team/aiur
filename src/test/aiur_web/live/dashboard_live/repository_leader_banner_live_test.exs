defmodule AiurWeb.DashboardLive.RepositoryLeaderBannerLiveTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias AiurWeb.DashboardLive.RepositoryLeaderBanner
  alias AiurWeb.Endpoint

  @endpoint Endpoint

  defp build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
  end

  test "runtime tick refreshes the rendered repository leader and lease age" do
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    Application.put_env(:aiur, Endpoint, Keyword.merge(previous_endpoint || [], server: false, dashboard_auth_required: false, secret_key_base: String.duplicate("s", 64)))
    Aiur.TestSupport.start_owned_endpoint!()

    {:ok, calls} = Agent.start_link(fn -> 0 end)
    now = DateTime.utc_now()

    leader_status = fn ->
      instance =
        Agent.get_and_update(calls, fn
          0 -> {"instance-a", 1}
          _ -> {"instance-b", 2}
        end)

      %{leader: instance, lease_age: if(instance == "instance-a", do: "3s", else: "7s"), observed_at: now, freshness: :fresh}
    end

    on_exit(fn ->
      RepositoryLeaderBanner.clear_clock()
      RepositoryLeaderBanner.clear_status_fun()
      if is_nil(previous_endpoint), do: Application.delete_env(:aiur, Endpoint), else: Application.put_env(:aiur, Endpoint, previous_endpoint)
    end)

    {:ok, view, _html} = live(build_conn(), "/units")

    :sys.replace_state(view.pid, fn state ->
      RepositoryLeaderBanner.put_status_fun(leader_status)
      state
    end)

    send(view.pid, :runtime_tick)
    assert render(view) =~ "Repository leader: instance-a · lease age 3s"

    :sys.replace_state(view.pid, fn state ->
      RepositoryLeaderBanner.put_clock(fn -> DateTime.add(now, 16, :second) end)
      state
    end)

    send(view.pid, :runtime_tick)

    assert render(view) =~ "Repository leader: instance-b · lease age 7s"
  end
end
