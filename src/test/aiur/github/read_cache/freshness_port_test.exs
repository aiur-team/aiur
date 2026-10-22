defmodule Aiur.GitHub.ReadCache.FreshnessPortTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.Access.{Settings, StaticSettings}
  alias Aiur.GitHub.ReadCache.Policy

  defmodule WebhookPort do
    @behaviour Aiur.GitHub.Access.Freshness

    @impl true
    def transport("port-owner/webhook-repo"), do: :webhook
    def transport(_repo), do: :polling

    @impl true
    def repo_config_transport(_repo, transport), do: transport
  end

  setup %{tmp_dir: root} = context do
    prior = Enum.map([:github_access_settings_provider, :github_access_settings], &{&1, Application.fetch_env(:aiur, &1)})
    on_exit(fn -> Aiur.TestSupport.restore_app_env(prior) end)
    Application.put_env(:aiur, :github_access_settings_provider, StaticSettings)
    Application.put_env(:aiur, :github_access_settings, Settings.new(root, freshness: Map.get(context, :port, WebhookPort)))
    :ok
  end

  @moduletag :tmp_dir

  test "a webhook-mode repo gets the long TTL through the port and a polling repo the short one" do
    assert {:cache, :issue, 3_600_000} = Policy.classify(issue("webhook-repo"))
    assert {:cache, :issue, 30_000} = Policy.classify(issue("polling-repo"))
  end

  @tag port: nil
  test "settings without a freshness port answer polling TTLs" do
    assert {:cache, :issue, 30_000} = Policy.classify(issue("webhook-repo"))
    assert {:cache, :repo_config, 300_000} = Policy.classify(rest("https://api.github.com/repos/port-owner/webhook-repo/actions/workflows?per_page=100"))
  end

  test "a verdict selection is still refused under a webhook-mode port" do
    document =
      "query Q { repository(owner: $o, name: $r) { t0: issueOrPullRequest(number: 7) { ... on PullRequest { statusCheckRollup { state } } } } }"

    request = %{
      method: :post,
      url: "https://api.github.com/graphql",
      token: "t",
      caller: "issue_relationships",
      body: %{"query" => document, "variables" => %{"owner" => "port-owner", "repo" => "webhook-repo"}}
    }

    assert {:no_cache, :unsafe_kind} = Policy.classify(request)
  end

  defp issue(repo), do: rest("https://api.github.com/repos/port-owner/#{repo}/issues/7")
  defp rest(url), do: %{method: :get, url: url, token: "t"}
end
