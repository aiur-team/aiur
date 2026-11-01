defmodule Aiur.GitHub.DispatchAuthorization.PageLimitMemoTest do
  import Aiur.GitHub.DispatchAuthorization.TestFixtures

  use Aiur.TestSupport

  alias Aiur.GitHub.DispatchAuthorization
  alias Aiur.GitHub.ReadCache

  setup do
    cache_snapshot = DispatchAuthorization.cache_snapshot_for_test()
    DispatchAuthorization.clear_cache()

    on_exit(fn -> DispatchAuthorization.restore_cache_for_test(cache_snapshot) end)

    :ok
  end

  test "memoizes an unchanged issue's page-limit deferral until its issue version changes" do
    ReadCache.reset()
    on_exit(&ReadCache.reset/0)
    counter = start_supervised!({Agent, fn -> 0 end})

    request_fun = fn %{url: url} ->
      page = url |> query_value("page") |> page_number()
      Agent.update(counter, &(&1 + 1))
      next = "https://api.github.com/repos/owner/repo/issues/42/timeline?per_page=50&page=#{page + 1}"
      {:ok, %{status: 200, headers: [{"link", "<#{next}>; rel=\"next\""}], body: []}}
    end

    original = issue(id: "53160091", identifier: "5316-91")

    first =
      DispatchAuthorization.authorize(original, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      )

    assert first.dispatch_authorization == :deferred
    assert Agent.get(counter, & &1) == 8

    second =
      DispatchAuthorization.authorize(original, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      )

    assert second.dispatch_authorization == :deferred
    assert Agent.get(counter, & &1) == 8

    updated = %{original | updated_at: ~U[2026-01-02 00:00:00Z]}

    third =
      DispatchAuthorization.authorize(updated, "owner", "repo", "agent",
        allowed_users: ["trusted"],
        token: "test-token",
        request_fun: request_fun
      )

    assert third.dispatch_authorization == :deferred
    assert Agent.get(counter, & &1) == 16
  end
end
