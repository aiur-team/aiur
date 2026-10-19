defmodule Aiur.GitHub.ReadCacheRequiredChecksTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{ReadCache, ReadCache.Metrics, ReadCache.Policy}

  setup do
    await_read_cache()
    ReadCache.reset()
    on_exit(&ReadCache.reset/0)
    :ok
  end

  test "required-check configuration is a repository-config read" do
    request = rest("https://api.github.com/repos/aiur-team/aiur/branches/main/protection")

    assert {:cache, :repo_config, 300_000} = Policy.classify(request)
  end

  test "caches an unprotected branch response" do
    request = rest("https://api.github.com/repos/aiur-team/aiur/branches/main/protection")
    response = {:ok, %{status: 404, body: %{"message" => "Not Found"}}}

    assert ^response = ReadCache.through(request, fn -> response end)
    assert ^response = ReadCache.through(request, fn -> flunk("cached 404") end)
    assert %{hit: 1, miss: 1, deposit: 1} = Metrics.snapshot().callers["ci_required_checks"]
  end

  test "404 responses for non-configuration classes are not cached" do
    request = %{method: :get, url: "https://api.github.com/repos/aiur-team/aiur/issues/2073", caller: "issue_reader"}
    response = {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
    assert ^response = ReadCache.through(request, fn -> response end)

    assert {:ok, %{status: 200, body: %{"id" => 2073}}} =
             ReadCache.through(request, fn -> {:ok, %{status: 200, body: %{"id" => 2073}}} end)
  end

  test "issue and check-run invalidations do not retire required-check policy" do
    request = rest("https://api.github.com/repos/aiur-team/aiur/branches/main/protection")
    response = {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["ci"]}}}}
    assert ^response = ReadCache.through(request, fn -> response end)

    :ok = ReadCache.invalidate_number("aiur-team/aiur", 2073)
    assert ^response = ReadCache.through(request, fn -> flunk("numbered invalidation must preserve config") end)
  end

  test "failed required-check responses are not cached and the next read retries" do
    request = rest("https://api.github.com/repos/aiur-team/aiur/branches/main/protection")
    failure = {:ok, %{status: 503, body: %{"message" => "unavailable"}}}
    success = {:ok, %{status: 200, body: %{"required_status_checks" => %{"contexts" => ["ci"]}}}}

    assert ^failure = ReadCache.through(request, fn -> failure end)
    assert ^success = ReadCache.through(request, fn -> success end)
    assert %{miss: 2, deposit: 1, not_deposited: 1} = Metrics.snapshot().callers["ci_required_checks"]
  end

  defp rest(url), do: %{method: :get, url: url, caller: "ci_required_checks"}

  defp await_read_cache(attempts \\ 100)

  defp await_read_cache(attempts) do
    cond do
      ReadCache.snapshot().available? -> :ok
      attempts > 0 -> Process.sleep(10) || await_read_cache(attempts - 1)
      true -> start_supervised!({ReadCache, sweep_interval_ms: 0})
    end
  end
end
