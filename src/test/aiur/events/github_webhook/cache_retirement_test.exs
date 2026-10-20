defmodule Aiur.Events.GithubWebhook.CacheRetirementTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.TrackerSettings
  alias Aiur.Events.GithubWebhook.Deposit.CacheRetirement
  alias Aiur.GitHub.{ReadCache, ResourceStore}

  setup do
    await_read_cache()
    ReadCache.reset()
    on_exit(&ReadCache.reset/0)
    :ok
  end

  test "numbered webhook invalidation preserves repo-config entries" do
    request = %{
      method: :get,
      url: "https://api.github.com/repos/aiur-team/aiur/branches/main/protection",
      caller: "ci_required_checks"
    }

    response = {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["ci"]}}}}
    assert ^response = ReadCache.through(request, fn -> response end)

    assert :ok =
             CacheRetirement.invalidate_read_cache(
               "check_run",
               %{"check_run" => %{"pull_requests" => [%{"number" => 2073}]}},
               "aiur-team/aiur"
             )

    assert ^response =
             ReadCache.through(request, fn ->
               flunk("check_run must not evict repository configuration")
             end)
  end

  test "configuration webhook retires repo-config entries" do
    request = %{
      method: :get,
      url: "https://api.github.com/repos/aiur-team/aiur/branches/main/protection",
      caller: "ci_required_checks"
    }

    first = {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["old"]}}}}
    second = {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["new"]}}}}
    assert ^first = ReadCache.through(request, fn -> first end)

    assert :ok =
             CacheRetirement.invalidate_read_cache(
               "branch_protection_rule",
               %{},
               "aiur-team/aiur"
             )

    assert ^second = ReadCache.through(request, fn -> second end)
  end

  test "pull-request webhook retires the shared open-pull-request listing" do
    key = ResourceStore.key_for_repo(:branch_pull_request_listing_all, "aiur-team/aiur", "open")
    assert :ok = ResourceStore.put_resource(key, [%{"number" => 2073}], etag: ~s("open-v1"))

    assert :ok =
             CacheRetirement.invalidate_read_cache(
               "pull_request",
               %{"pull_request" => %{"number" => 2073}},
               "aiur-team/aiur"
             )

    assert :miss = ResourceStore.fetch(key)
  end

  test "push to repository default branch retires config when it differs from tracker base" do
    request = %{
      method: :get,
      url: "https://api.github.com/repos/aiur-team/aiur/branches/main/protection",
      caller: "ci_required_checks"
    }

    first = {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["old"]}}}}
    second = {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["new"]}}}}
    assert ^first = ReadCache.through(request, fn -> first end)

    default_branch = TrackerSettings.base_branch() <> "-default"

    feature_push = %{
      "ref" => "refs/heads/feature",
      "repository" => %{"default_branch" => default_branch}
    }

    assert :ok = CacheRetirement.invalidate_read_cache("push", feature_push, "aiur-team/aiur")

    assert ^first =
             ReadCache.through(request, fn -> flunk("feature push must preserve repo config") end)

    default_push = %{
      "ref" => "refs/heads/" <> default_branch,
      "repository" => %{"default_branch" => default_branch}
    }

    assert :ok = CacheRetirement.invalidate_read_cache("push", default_push, "aiur-team/aiur")
    assert ^second = ReadCache.through(request, fn -> second end)
  end

  test "push without default branch metadata conservatively retires repo config" do
    request = %{
      method: :get,
      url: "https://api.github.com/repos/aiur-team/aiur/branches/main/protection",
      caller: "ci_required_checks"
    }

    first = {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["old"]}}}}
    second = {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["new"]}}}}
    assert ^first = ReadCache.through(request, fn -> first end)

    push = %{"ref" => "refs/heads/feature"}
    assert :ok = CacheRetirement.invalidate_read_cache("push", push, "aiur-team/aiur")
    assert ^second = ReadCache.through(request, fn -> second end)
  end

  test "push to tracker base branch retires repo config" do
    request = %{
      method: :get,
      url: "https://api.github.com/repos/aiur-team/aiur/branches/main/protection",
      caller: "ci_required_checks"
    }

    first = {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["old"]}}}}
    second = {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["new"]}}}}
    assert ^first = ReadCache.through(request, fn -> first end)

    repository_default = TrackerSettings.base_branch() <> "-default"

    base_push = %{
      "ref" => "refs/heads/" <> TrackerSettings.base_branch(),
      "repository" => %{"default_branch" => repository_default}
    }

    assert :ok = CacheRetirement.invalidate_read_cache("push", base_push, "aiur-team/aiur")
    assert ^second = ReadCache.through(request, fn -> second end)
  end

  defp await_read_cache(attempts \\ 100)

  defp await_read_cache(attempts) do
    if ReadCache.snapshot().available?,
      do: :ok,
      else:
        if(attempts > 0,
          do:
            (
              Process.sleep(10)
              await_read_cache(attempts - 1)
            ),
          else: start_supervised!({ReadCache, sweep_interval_ms: 0})
        )
  end
end
