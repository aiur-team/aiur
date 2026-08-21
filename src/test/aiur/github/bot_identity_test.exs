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

  # Regression for #2133. `write_workflow_file!/2` writes the fixture and blocks
  # on `WorkflowStore.force_reload/1`, so the shared singleton's cache is
  # supposed to be holding this case's config when the call returns. A reload
  # from another path — the in-VM shape of a leftover teardown or background
  # reload landing between the write-await and the read — used to re-point the
  # singleton at a config this case did not write, dropping `bot_account` and
  # tripping the viewer-lookup fallthrough. The read is now fenced to this
  # case's own path, so the clobbered cache entry is refused and the config on
  # disk is read instead.
  test "write-then-read is not clobbered by a concurrent reload from another path" do
    path = Workflow.workflow_file_path()

    write_workflow_file!(path,
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_bot_account: "config-bot"
    )

    other = Path.join(Path.dirname(path), "bot-identity-other-config.yaml")

    write_workflow_file!(other,
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_bot_account: nil
    )

    store = Process.whereis(WorkflowStore)

    # A background reload source re-points the shared singleton at `other` and
    # reloads it, then moves the path back — leaving the cache holding a config
    # that is not this case's while this case's own path is unchanged. Suspending
    # the store keeps its own poll from healing the stale cache mid-assertion.
    Task.async(fn ->
      Workflow.set_workflow_file_path(other)
      :ok = WorkflowStore.force_reload()
      Application.put_env(:aiur, :workflow_file_path, path)
    end)
    |> Task.await()

    :sys.suspend(store)

    on_exit(fn ->
      if Process.alive?(store), do: :sys.resume(store)
      Workflow.set_workflow_file_path(path)
      ensure_workflow_store_running()
      :ok = WorkflowStore.force_reload()
    end)

    request_fun = fn _ -> flunk("viewer lookup should not run when config provides bot_account") end
    assert BotIdentity.bot_account([], request_fun, "token") == {:ok, "config-bot"}
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

  # Under a split identity, "not a human reviewer" covers both logins Aiur
  # writes under. Listing only one would let the other's comment stand as a
  # human's judgement on the change, which releases a ticket nobody reviewed.
  test "classifies both the agent account and the daemon App bot as Aiur's own" do
    opts = BotIdentity.codeowners_classification_opts(bot_account: "its-applekid", daemon_account: "aiur-daemon[bot]")

    assert Keyword.get(opts, :agent_logins) == ["its-applekid", "aiur-daemon[bot]"]
    assert BotIdentity.agent_login?("its-applekid", opts)
    assert BotIdentity.agent_login?("aiur-daemon[bot]", opts)
    refute BotIdentity.agent_login?("its-everdred", opts)
  end

  # Single-identity installs are the shipped default and must keep the exact
  # list they had before `github_app` existed — one entry, not a duplicate pair.
  test "collapses to one login when the daemon and the agents share an account" do
    opts = BotIdentity.codeowners_classification_opts(bot_account: "aiur-bot", daemon_account: "aiur-bot")

    assert Keyword.get(opts, :agent_logins) == ["aiur-bot"]
  end
end
