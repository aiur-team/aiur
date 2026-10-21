defmodule Aiur.GitHub.ReadCacheRepoConfigTtlTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.GithubWebhook
  alias Aiur.GitHub.ReadCache.Policy
  alias Aiur.Webhooks.{DeliveryMode, ModeTable}

  @repo "aiur-team/repo-config-ttl-test"
  @request %{
    method: :get,
    url: "https://api.github.com/repos/aiur-team/repo-config-ttl-test/rulesets"
  }

  setup do
    ModeTable.delete(@repo)
    ModeTable.delete_config_events(@repo)
    on_exit(fn -> ModeTable.delete(@repo) && ModeTable.delete_config_events(@repo) end)
    :ok
  end

  test "push and the live hook event families keep the short TTL until both config events arrive" do
    ModeTable.put(@repo, webhook_mode())
    assert_short_ttl()

    for event <- ["push", "issues", "check_run", "pull_request", "repository"] do
      _result = deliver(event)
      assert_short_ttl()
    end

    _result = deliver("branch_protection_rule")
    assert_short_ttl()

    _result = deliver("repository_ruleset")
    assert {:cache, :repo_config, 3_600_000} = Policy.classify(@request)
  end

  test "losing webhook transport clears observed config coverage" do
    ModeTable.put(@repo, webhook_mode())
    deliver("branch_protection_rule")
    deliver("repository_ruleset")
    assert {:cache, :repo_config, 3_600_000} = Policy.classify(@request)

    ModeTable.put(@repo, DeliveryMode.new(@repo, configured?: true))

    assert_short_ttl()
  end

  defp webhook_mode do
    {mode, :proven} = DeliveryMode.new(@repo) |> DeliveryMode.record_delivery(DateTime.utc_now())
    mode
  end

  defp deliver("push") do
    GithubWebhook.handle_delivery(
      "push",
      %{
        "ref" => "refs/heads/feature",
        "repository" => %{"full_name" => @repo, "default_branch" => "main"}
      },
      repo: @repo
    )
  end

  defp deliver(event) do
    GithubWebhook.handle_delivery(
      event,
      %{"repository" => %{"full_name" => @repo}},
      repo: @repo
    )
  end

  defp assert_short_ttl do
    assert {:cache, :repo_config, 300_000} = Policy.classify(@request)
  end
end
