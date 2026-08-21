# Runs the `/github-cache` page locally against a synthetic quota meter, so the
# "what is spending the budget" layer can be looked at rather than inferred from
# a passing test.
#
#     cd src && AIUR_GHC_PORT=4099 AIUR_GHC_TMP=/tmp/aiur-ghc-tmp \
#       mise exec -- mix run --no-start test/manual/github_cache_usage_fixture.exs
#
# Nothing here reaches GitHub: the meter is fed hand-written responses and the
# cache source enumerates an ETS table, which is the same property the page
# itself is built to demonstrate.

defmodule Aiur.Manual.GithubCacheUsageFixture do
  @moduledoc false

  alias Aiur.GitHub.Quota
  alias Aiur.GitHub.QuotaHistory
  alias Aiur.GitHub.ResourceStore
  alias AiurWeb.FinancialDataAccess.Generation

  # The measured incident, so what renders is what an operator actually saw.
  @graphql [
    {:comment_poll_batch, 9, 93},
    {:review_threads_unaddressed, 50, 50},
    {:ci_poll_batch, 10, 10},
    {:build_order_catalog, 8, 8},
    {:build_order_pack_status, 4, 4},
    {:pr_review_state, 3, 6}
  ]

  def run do
    tmp = System.get_env("AIUR_GHC_TMP", "/tmp/aiur-ghc-tmp")
    port = String.to_integer(System.get_env("AIUR_GHC_PORT", "4099"))

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    Application.put_env(:aiur, :log_file, Path.join(tmp, "aiur.log"))
    Application.put_env(:aiur, :state_dir, tmp)

    {:ok, _started} = Application.ensure_all_started(:bandit)
    {:ok, _started} = Application.ensure_all_started(:phoenix_live_view)

    {:ok, _pid} =
      Supervisor.start_link(
        [{Phoenix.PubSub, name: Aiur.PubSub}, {Task.Supervisor, name: Aiur.TaskSupervisor}],
        strategy: :one_for_one
      )

    System.put_env("AIUR_DASHBOARD_USERNAME", "example")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "example")
    {:ok, _pid} = Generation.start_link([])
    {:ok, _pid} = AiurWeb.FinancialData.start_link([])

    {:ok, _pid} = ResourceStore.start_link([])
    start_quota(tmp)
    {:ok, _pid} = QuotaHistory.start_link(interval_ms: 5_000)

    configure_endpoint(port)
    {:ok, _pid} = AiurWeb.Endpoint.start_link()

    IO.puts("GitHub cache usage fixture ready at http://127.0.0.1:#{port}/github-cache")
    Process.sleep(:infinity)
  end

  defp start_quota(tmp) do
    {:ok, _pid} =
      Quota.start_link(
        refresh?: false,
        emit_fun: fn _kind, _payload -> :ok end,
        shell_log_path: Path.join(tmp, "github-shell-quota.ndjson"),
        hold_dir: Path.join(tmp, "github-holds")
      )

    reset = DateTime.utc_now() |> DateTime.add(1_920, :second) |> DateTime.to_unix()

    for {caller, calls, points} <- @graphql, _call <- 1..calls do
      # The last caller is billed at an assumed point: its response never
      # carried a price, which is the row the page has to mark rather than
      # quietly average into the ranking.
      cost = if caller == :pr_review_state, do: nil, else: div(points, calls)
      Quota.observe(graphql_request(caller), graphql_response(cost, reset))
    end

    for _call <- 1..88, do: Quota.observe(core_request(), core_response(reset))

    _settle = Quota.snapshot()
    :ok
  end

  defp graphql_request(caller) do
    %{
      method: :post,
      url: "https://api.github.com/graphql",
      token: "fixture",
      caller: caller,
      body: %{"query" => "query Fixture { viewer { login } }"}
    }
  end

  defp graphql_response(cost, reset) do
    data = if is_integer(cost), do: %{"rateLimit" => %{"cost" => cost}}, else: %{}

    # 3,640 of 5,000 remaining: the ranking explains 171 points of a 1,360-point
    # bill, which is the shape that made the remainder band necessary.
    {:ok,
     %{
       status: 200,
       headers: [
         {"x-ratelimit-resource", "graphql"},
         {"x-ratelimit-limit", "5000"},
         {"x-ratelimit-remaining", "3640"},
         {"x-ratelimit-reset", Integer.to_string(reset)}
       ],
       body: %{"data" => data}
     }}
  end

  defp core_request, do: %{method: :get, url: "https://api.github.com/repos/example/repository", token: "fixture", caller: :bot_identity}

  defp core_response(reset) do
    {:ok,
     %{
       status: 200,
       headers: [
         {"x-ratelimit-resource", "core"},
         {"x-ratelimit-limit", "5000"},
         {"x-ratelimit-remaining", "4912"},
         {"x-ratelimit-reset", Integer.to_string(reset)}
       ],
       body: %{}
     }}
  end

  defp configure_endpoint(port) do
    config =
      :aiur
      |> Application.get_env(AiurWeb.Endpoint, [])
      |> Keyword.merge(
        http: [ip: {127, 0, 0, 1}, port: port],
        server: true,
        secret_key_base: String.duplicate("f", 64),
        dashboard_writable: false,
        dashboard_auth_required: false,
        live_view: [signing_salt: "fixturesalt"]
      )

    Application.put_env(:aiur, AiurWeb.Endpoint, config)
  end
end

Aiur.Manual.GithubCacheUsageFixture.run()
