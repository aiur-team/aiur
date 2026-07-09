defmodule Aiur.GitHub.BotIdentityTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.BotIdentity
  alias Aiur.GitHub.Transport

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_bot_account: nil
    )

    :ok
  end

  test "resolves bot account from opts before config or viewer lookup" do
    request_fun = fn _ -> flunk("viewer lookup should not run when opts provide bot_account") end

    assert BotIdentity.bot_account([bot_account: " aiur-bot "], request_fun, "token") ==
             {:ok, "aiur-bot"}
  end

  test "falls back from config bot account to authenticated viewer login" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_bot_account: "config-bot"
    )

    request_fun = fn _ -> flunk("viewer lookup should not run when config provides bot_account") end
    assert BotIdentity.bot_account([], request_fun, "token") == {:ok, "config-bot"}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_bot_account: nil
    )

    request_fun = fn req ->
      assert req.method == :post
      assert req.url == Transport.graphql_url()
      assert req.body["query"] =~ "viewer"
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "viewer-bot"}}}}}
    end

    assert BotIdentity.bot_account([], request_fun, "token") == {:ok, "viewer-bot"}
  end

  test "reports missing viewer login" do
    request_fun = fn _ -> {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => " "}}}}} end

    assert BotIdentity.fetch_authenticated_viewer_login(request_fun, "token") ==
             {:error, :github_viewer_login_missing}
  end

  test "normalizes agent login classification options" do
    opts = BotIdentity.codeowners_classification_opts(bot_account: " aiur-bot ", agent_logins: ["dev", nil, "dev"])

    assert Keyword.get(opts, :agent_logins) == ["aiur-bot", "dev"]
    assert BotIdentity.agent_login?("aiur-bot", opts)
    refute BotIdentity.agent_login?("human", opts)
    assert BotIdentity.normalize_optional_binary(" aiur-bot ") == "aiur-bot"
    assert BotIdentity.normalize_optional_binary(" ") == nil
    assert BotIdentity.normalize_optional_binary(nil) == nil
  end
end
