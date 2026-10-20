defmodule Aiur.GitHub.ReadCacheRepoConfigTtlTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.GithubWebhook
  alias Aiur.GitHub.ReadCache.Policy
  alias Aiur.Webhooks.{DeliveryMode, ModeTable}

  @repo "aiur-team/repo-config-ttl-test"

  setup do
    ModeTable.delete(@repo)
    ModeTable.delete_config_events(@repo)
    on_exit(fn -> ModeTable.delete(@repo) && ModeTable.delete_config_events(@repo) end)
    :ok
  end

  test "a webhook-backed repo uses the short config TTL until a config event arrives" do
    {mode, :proven} = DeliveryMode.new(@repo) |> DeliveryMode.record_delivery(DateTime.utc_now())
    ModeTable.put(@repo, mode)
    request = %{method: :get, url: "https://api.github.com/repos/aiur-team/repo-config-ttl-test/rulesets"}

    assert {:cache, :repo_config, 300_000} = Policy.classify(request)

    assert %{status: :dropped} =
             GithubWebhook.handle_delivery(
               "repository_ruleset",
               %{"repository" => %{"full_name" => @repo}},
               repo: @repo
             )

    assert {:cache, :repo_config, 3_600_000} = Policy.classify(request)
  end
end
