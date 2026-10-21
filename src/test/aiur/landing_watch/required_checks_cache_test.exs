defmodule Aiur.LandingWatch.RequiredChecksCacheTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{CiReadiness, ReadCache}
  alias Aiur.LandingWatch
  alias Aiur.Webhooks.ModeTable

  @repo "owner/repo"

  setup do
    await_read_cache()
    ReadCache.reset()
    ModeTable.delete(@repo)

    on_exit(fn ->
      ReadCache.reset()
      ModeTable.delete(@repo)
    end)

    :ok
  end

  test "landing polls over multiple PRs fetch required-check config once per shared TTL" do
    Process.put(:required_checks_fetches, 0)

    request_fun = fn request ->
      ReadCache.through(request, fn ->
        Process.put(:required_checks_fetches, Process.get(:required_checks_fetches) + 1)

        if String.contains?(request.url, "/rules/branches/") do
          {:ok, %{status: 200, body: []}}
        else
          {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
        end
      end)
    end

    observations = Enum.map(1..4, &approved_observation/1)

    Enum.each(1..5, fn _poll ->
      assert :ok =
               LandingWatch.poll(
                 observe_fun: fn _opts -> {:ok, observations} end,
                 journal_prune_fun: fn _, _ -> :ok end,
                 required_checks_fun: fn _opts ->
                   CiReadiness.fetch_required_checks(
                     repo: @repo,
                     base_branch: "main",
                     token: "test-token",
                     request_fun: request_fun
                   )
                 end,
                 approved_fun: fn _, _ -> {:ok, false} end,
                 ci_status_fun: fn _, _ -> {:ok, %{check_runs: [], commit_status: %{"state" => "success", "statuses" => []}}} end,
                 queue_reconcile_fun: fn _, _ -> :ok end
               )
    end)

    assert Process.get(:required_checks_fetches) == 2
    assert ReadCache.snapshot().callers["ci_required_checks"].hit == 8
  after
    Process.delete(:required_checks_fetches)
  end

  defp approved_observation(number) do
    head = "head-#{number}"

    %{
      number: number,
      raw: %{
        "reviewDecision" => "APPROVED",
        "headRefOid" => head,
        "reviews" => %{"nodes" => [%{"commit" => %{"oid" => head}}]}
      }
    }
  end

  defp await_read_cache(attempts \\ 100)

  defp await_read_cache(attempts) do
    if ReadCache.snapshot().available? do
      :ok
    else
      if attempts > 0 do
        Process.sleep(10)
        await_read_cache(attempts - 1)
      else
        start_supervised!({ReadCache, sweep_interval_ms: 0})
      end
    end
  end
end
