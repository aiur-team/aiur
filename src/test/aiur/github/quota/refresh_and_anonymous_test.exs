defmodule Aiur.GitHub.Quota.RefreshAndAnonymousTest do
  use Aiur.TestSupport

  import Aiur.GitHub.QuotaTestSupport

  alias Aiur.GitHub.Quota

  @now ~U[2026-08-09 21:00:00Z]
  @reset ~U[2026-08-09 22:00:00Z]

  test "refreshes immediately and schedules the next probe after completion" do
    parent = self()

    _quota =
      start_quota(
        refresh?: true,
        refresh_interval_ms: 10,
        refresh_fun: fn -> send(parent, :refreshed) end
      )

    assert_receive :refreshed, 500
    assert_receive :refreshed, 500
  end

  test "a scheduled refresh that restores headroom wakes fleet admission without restarting" do
    parent = self()
    name = :"github-quota-recovery-#{System.unique_integer([:positive])}"
    {:ok, quota_state} = Agent.start_link(fn -> {@now, 500} end)

    refresh_fun = fn ->
      {now, remaining} = Agent.get(quota_state, & &1)
      reset = now |> DateTime.add(900, :second) |> DateTime.to_unix()

      Quota.observe(
        name,
        request(:get, "/rate_limit"),
        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{
             "resources" => %{
               "core" => %{"limit" => 5000, "remaining" => remaining, "reset" => reset},
               "graphql" => %{"limit" => 5000, "remaining" => 5000, "reset" => reset}
             }
           }
         }}
      )
    end

    quota =
      start_quota(
        name: name,
        refresh?: true,
        refresh_interval_ms: 10,
        refresh_fun: refresh_fun,
        clock: fn -> quota_state |> Agent.get(&elem(&1, 0)) end,
        recovery_fun: fn -> send(parent, :github_quota_recovered) end
      )

    assert eventually(fn -> match?({:hold, %{resource: "core", remaining: 500}}, Quota.dispatch_status(quota)) end)
    refute_receive :github_quota_recovered, 100

    Agent.update(quota_state, fn {_now, _remaining} -> {DateTime.add(@reset, 1, :second), 4500} end)

    assert_receive :github_quota_recovered, 500
    assert eventually(fn -> Quota.dispatch_status(quota) == :available end)
    refute_receive :github_quota_recovered, 30
  end

  test "a primary window reset wakes fleet admission without another observation" do
    parent = self()
    {:ok, clock} = Agent.start_link(fn -> @now end)

    quota =
      start_quota(
        clock: fn -> Agent.get(clock, & &1) end,
        recovery_fun: fn -> send(parent, :github_quota_recovered) end
      )

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues"), response("core", 5000, 500))
    assert {:hold, %{resource: "core"}} = Quota.dispatch_status(quota)

    token = :sys.get_state(quota).recovery_timer_token
    Agent.update(clock, fn _ -> DateTime.add(@reset, 1, :second) end)
    send(quota, {:dispatch_recovery, token})

    assert_receive :github_quota_recovered, 1000
    assert Quota.dispatch_status(quota) == :available
  end

  # An anonymous read spends the 60/hr unauthenticated IP allowance. GitHub
  # still labels the response `core`, so keying off the header alone would let a
  # `limit: 60` window overwrite the authenticated one and hold the whole fleet.
  test "meters anonymous reads in their own window instead of the authenticated core one" do
    quota = start_quota()

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 3750))
    Quota.observe(quota, anonymous_request("/repos/owner/repo/contents/CODEOWNERS"), response("core", 60, 2))

    snapshot = Quota.snapshot(quota)

    assert snapshot.windows["core"].limit == 5000
    assert snapshot.windows["core"].remaining == 3750

    assert snapshot.windows["core:anonymous"].limit == 60
    assert snapshot.windows["core:anonymous"].remaining == 2
  end

  test "an exhausted anonymous allowance does not hold authenticated dispatch" do
    quota = start_quota()

    Quota.observe(quota, request(:get, "/repos/owner/repo/issues/1670"), response("core", 5000, 5000))
    Quota.observe(quota, anonymous_request("/repos/owner/repo/contents/CODEOWNERS"), response("core", 60, 0))

    assert Quota.dispatch_status(quota) == :available
    assert Quota.preflight(quota, request(:get, "/repos/owner/repo/issues/1670")) == :ok
  end

  test "holds a further anonymous read once the anonymous allowance is exhausted" do
    quota = start_quota()

    Quota.observe(quota, anonymous_request("/repos/owner/repo/contents/CODEOWNERS"), response("core", 60, 0))

    assert {:hold, hold} = Quota.preflight(quota, anonymous_request("/repos/owner/repo/contents/CODEOWNERS"))
    assert hold.resource == "core:anonymous"
  end
end
