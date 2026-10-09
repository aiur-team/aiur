defmodule Aiur.GitHub.CodeownersTrustSnapshotTest do
  use Aiur.TestSupport
  alias Aiur.AgentRunner.EventsDigest
  alias Aiur.Codeowners
  alias Aiur.Events.{PrCommandScanner, Sanitizer}
  alias Aiur.GitHub.{CodeOwners, PullRequests, TrustSnapshot}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_trusted_accounts: ["configured"])
    path = Path.join(root, "CODEOWNERS")
    File.write!(path, "* @acme/team @direct # trailing comment\n")
    %{path: path, root: root}
  end

  test "page two failure discards page one members and exposes cause and age", %{path: path} do
    request = fn %{url: url} ->
      if url =~ "page=2", do: {:ok, %{status: 503, body: %{}}}, else: first_page()
    end

    server = start_snapshot(path, request)
    snapshot = CodeOwners.trust_snapshot(server)
    refute CodeOwners.allowed?("member", server)
    assert CodeOwners.allowed?("direct", server)
    assert CodeOwners.allowed?("configured", server)
    assert CodeOwners.allowed?("owner", server)
    assert %{cause: {:team_lookup_failed, "@acme/team", {:github, :http, %{status: 503}}}, observed_at: %DateTime{}} = snapshot.degradation
    assert TrustSnapshot.status_suffix(snapshot) =~ ~r/age \d+s/
  end

  test "refresh denies previously trusted members and alerts once until recovery", %{path: path} do
    {:ok, mode} = Agent.start_link(fn -> :success end)
    parent = self()

    request = fn _ ->
      case Agent.get(mode, & &1) do
        :success -> {:ok, %{status: 200, body: [%{"login" => "member"}], headers: []}}
        :failure -> {:ok, %{status: 403, body: %{}}}
      end
    end

    server = start_snapshot(path, request, fn name, message, _ -> send(parent, {:alert, name, message}) end)
    assert CodeOwners.allowed?("member", server)
    Agent.update(mode, fn _ -> :failure end)
    CodeOwners.refresh(server)
    refute CodeOwners.allowed?("member", server)
    assert_received {:alert, "github.codeowners.degraded", message}
    assert message =~ "@acme/team"
    assert message =~ ~r/age \d+s/
    observed = CodeOwners.trust_snapshot(server).degradation.observed_at
    CodeOwners.refresh(server)
    assert CodeOwners.trust_snapshot(server).degradation.observed_at == observed
    refute_received {:alert, "github.codeowners.degraded", _}
    Agent.update(mode, fn _ -> :success end)
    CodeOwners.refresh(server)
    assert CodeOwners.allowed?("member", server)
    assert CodeOwners.trust_snapshot(server).degradation == nil
  end

  test "trailing comments use the same grammar for trust and path ownership", %{path: path, root: root} do
    File.write!(path, "* @direct # trailing comment\n")
    server = start_snapshot(path, fn _ -> flunk("no teams to fetch") end)
    assert CodeOwners.trust_snapshot(server).degradation == nil
    assert CodeOwners.allowed?("direct", server)
    assert Codeowners.owners_for_path("lib/app.ex", repo_root: root) == ["direct"]
  end

  test "incomplete PR file collection cannot grant authority from the first page", %{root: root, path: path} do
    File.write!(path, "* @direct\n")

    request = fn %{url: url} ->
      if url =~ "page=2" do
        {:ok, %{status: 503, body: %{}}}
      else
        {:ok, %{status: 200, body: [%{"filename" => "lib/app.ex"}], headers: next_link()}}
      end
    end

    context = Codeowners.owners_for_pr(42, repo_root: root, repo: "owner/repo", token: "token", request_fun: request)
    assert {:error, {:github, :http, %{status: 503}}} = context
    assert Codeowners.authoritative?("direct", context) == nil
  end

  test "malformed CODEOWNERS is unknown for path authority", %{root: root, path: path} do
    File.write!(path, "* @direct\n!bad @outsider\n")
    context = Codeowners.ownership_for_path("lib/app.ex", repo_root: root)
    assert context == {:error, {:unparseable, 2}}
    assert Codeowners.authoritative?("direct", context) == nil
  end

  test "later team page failure makes the whole path ownership unknown", %{root: root} do
    request = fn %{url: url} ->
      if url =~ "page=2", do: {:ok, %{status: 503, body: %{}}}, else: first_page()
    end

    context = Codeowners.ownership_for_path("lib/app.ex", repo_root: root, token: "token", request_fun: request)
    assert context == {:error, {:github_api_status, 503}}
    assert Codeowners.authoritative?("direct", context) == nil
  end

  test "unresolved team author stays visible but loses digest and command authority", %{path: path} do
    {:ok, mode} = Agent.start_link(fn -> :success end)

    request = fn _ ->
      if Agent.get(mode, & &1) == :success, do: {:ok, %{status: 200, body: [%{"login" => "member"}], headers: []}}, else: {:ok, %{status: 403, body: %{}}}
    end

    server = start_snapshot(path, request)
    assert CodeOwners.allowed?("member", server)
    Agent.update(mode, fn _ -> :failure end)
    CodeOwners.refresh(server)
    previous = Process.whereis(CodeOwners)
    if previous, do: Process.unregister(CodeOwners)
    Process.register(server, CodeOwners)

    on_exit(fn ->
      if Process.whereis(CodeOwners) == server, do: Process.unregister(CodeOwners)
      if previous && Process.alive?(previous), do: Process.register(previous, CodeOwners)
    end)

    payload = %{author: "member", comment: %{"user" => %{"login" => "member"}, "body" => "/aiur <request>"}}
    sanitized = payload |> Sanitizer.scrub() |> Sanitizer.stamp_author_trust() |> Sanitizer.put_comment_message()
    assert sanitized.comment["body"] == "/aiur &lt;request&gt;"
    assert sanitized.author_trusted? == false
    refute PrCommandScanner.command?(Map.put(sanitized.comment, :author_trusted?, sanitized.author_trusted?), "/aiur", nil)
    event = Map.merge(sanitized, %{id: 1, source: :github, topic: "ticket.3295.issue.commented"})
    refute EventsDigest.render([event], "3295") =~ "request"
  end

  test "origin owner stays trusted during failure; unavailable origin never retains old members", %{path: path} do
    key = {Aiur.GitHub.Config, :resolved_origin_repo}
    old = :persistent_term.get(key, :unset)

    on_exit(fn ->
      if old == :unset, do: :persistent_term.erase(key), else: :persistent_term.put(key, old)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_trusted_accounts: ["configured"])
    :persistent_term.put(key, "origin-owner/repo")
    File.write!(path, "* @direct\n")
    server = start_snapshot(path, fn _ -> flunk("no team") end)
    assert CodeOwners.allowed?("origin-owner", server)
    :persistent_term.put(key, nil)
    File.write!(path, "# empty\n")
    CodeOwners.refresh(server)
    refute CodeOwners.allowed?("direct", server)
    refute CodeOwners.allowed?("origin-owner", server)
    assert CodeOwners.allowed?("configured", server)
    File.write!(path, "* @direct\n")
    CodeOwners.refresh(server)
    assert CodeOwners.trust_snapshot(server).degradation.cause == :repo_owner_unknown
  end

  test "failed refresh clears the last member when configured accounts and origin are absent", %{path: path} do
    key = {Aiur.GitHub.Config, :resolved_origin_repo}
    old = :persistent_term.get(key, :unset)
    :persistent_term.put(key, nil)

    on_exit(fn ->
      if old == :unset, do: :persistent_term.erase(key), else: :persistent_term.put(key, old)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github")
    File.write!(path, "* @acme/team\n")
    {:ok, mode} = Agent.start_link(fn -> :success end)

    request = fn _ ->
      if Agent.get(mode, & &1) == :success, do: {:ok, %{status: 200, body: [%{"login" => "member"}], headers: []}}, else: {:ok, %{status: 403, body: %{}}}
    end

    server = start_snapshot(path, request)
    assert CodeOwners.allowed?("member", server)
    Agent.update(mode, fn _ -> :failure end)
    CodeOwners.refresh(server)
    refute CodeOwners.allowed?("member", server)
    assert CodeOwners.trust_snapshot(server).trusted == []
    assert {:team_lookup_failed, "@acme/team", {:github, :http, %{status: 403}}} = CodeOwners.trust_snapshot(server).degradation.cause
  end

  test "malformed PR file records make authority unknown", %{root: root} do
    for entry <- [%{}, %{"filename" => nil}, %{"filename" => ""}, %{"filename" => 42}] do
      request = fn _ -> {:ok, %{status: 200, body: [entry], headers: []}} end
      context = Codeowners.owners_for_pr(42, repo_root: root, repo: "owner/repo", token: "token", request_fun: request)
      assert context == {:error, :invalid_pr_files_response}
      assert Codeowners.authoritative?("direct", context) == nil
      assert PullRequests.fetch_pull_request_changed_paths(42, request_fun: request) == context
    end
  end

  test "malformed team membership never produces a smaller authoritative set", %{path: path, root: root} do
    request = fn _ -> {:ok, %{status: 200, body: [%{"login" => "member"}, %{}], headers: []}} end
    server = start_snapshot(path, request)
    refute CodeOwners.allowed?("member", server)
    assert CodeOwners.trust_snapshot(server).degradation.cause == {:team_lookup_failed, "@acme/team", :invalid_team_response}
    context = Codeowners.ownership_for_path("lib/app.ex", repo_root: root, request_fun: request)
    assert context == {:error, {:github_api_request, :invalid_team_response}}
    assert Codeowners.authoritative?("direct", context) == nil
  end

  test "a PR-file collection at GitHub's 3000-file cap is unknown, not complete", %{root: root, path: path} do
    File.write!(path, "* @direct\n")
    files = for n <- 1..3000, do: %{"filename" => "lib/file_#{n}.ex"}
    request = fn _ -> {:ok, %{status: 200, body: files, headers: []}} end
    context = Codeowners.owners_for_pr(42, repo_root: root, repo: "owner/repo", token: "token", request_fun: request)
    assert context == {:error, :pr_files_truncated}
    assert Codeowners.authoritative?("direct", context) == nil
    assert PullRequests.fetch_pull_request_changed_paths(42, request_fun: request) == context
  end

  test "path ownership follows GitHub's last-match and gitignore semantics", %{root: root, path: path} do
    File.write!(path, """
    * @everyone
    secrets/ @security
    apps/github @apps
    docs/* @docs
    **/logs @logs
    /my\\ dir/ @spaces
    """)

    owners = &Codeowners.owners_for_path(&1, repo_root: root)
    assert owners.("config/secrets/key.pem") == ["security"]
    assert owners.("secrets") == ["everyone"]
    assert owners.("apps/github/client.ex") == ["apps"]
    assert owners.("docs/intro.md") == ["docs"]
    assert owners.("docs/build/intro.md") == ["everyone"]
    assert owners.("logs/a.log") == ["logs"]
    assert owners.("deep/logs/a.log") == ["logs"]
    assert owners.("my dir/file.txt") == ["spaces"]
    assert owners.("README.md") == ["everyone"]
  end

  defp start_snapshot(path, request, alert \\ fn _, _, _ -> :ok end) do
    start_supervised!({CodeOwners, name: nil, path: path, request_fun: request, alert_fun: alert, refresh_seconds: 86_400})
  end

  defp first_page, do: {:ok, %{status: 200, body: [%{"login" => "member"}], headers: next_link()}}
  defp next_link, do: [{"link", "<https://api.github.com/orgs/acme/teams/team/members?page=2>; rel=\"next\""}]
end
