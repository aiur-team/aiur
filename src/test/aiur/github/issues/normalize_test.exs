defmodule Aiur.GitHub.Issues.NormalizeTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Issues

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @origin_cache_key {Aiur.GitHub.Config, :resolved_origin_repo}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    :ok
  end

  describe "normalize_issue/4" do
    test "maps github issue fields to Issue struct" do
      gh = %{
        "number" => 10,
        "node_id" => "I_kwDOIssue10",
        "title" => "Test issue",
        "body" => "body text",
        "html_url" => "https://github.com/owner/repo/issues/10",
        "labels" => [%{"name" => "sym:todo"}, %{"name" => "priority:1"}],
        "user" => %{"login" => "creator"},
        "assignee" => %{"login" => "alice"},
        "state" => "open",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")

      assert issue.id == "10"

      assert %{
               status: :joinable,
               kind: :github,
               owner: "owner",
               repository: "repo",
               provider_id: "I_kwDOIssue10",
               identifier: "10"
             } =
               issue.tracker_identity

      assert issue.title == "Test issue"
      assert issue.priority == 1
      assert issue.state == "todo"
      assert issue.assignee_id == "alice"
      assert issue.creator_login == "creator"
      refute issue.dispatch_authorized?
      assert issue.paused == false
    end

    test "marks repository-mismatched and missing-node responses explicitly nonjoinable" do
      mismatched = %{
        "number" => 14,
        "node_id" => "I_kwDOIssue14",
        "repository_url" => "https://api.github.com/repos/other/repo",
        "labels" => []
      }

      missing_node = %{"number" => 15, "title" => "Legacy response", "labels" => []}

      assert %{status: :unjoinable, reason: :repository_mismatch} =
               Issues.normalize_issue(mismatched, "owner", "repo", "sym").tracker_identity

      assert %{status: :unjoinable, reason: :missing_provider_identity, identifier: "15"} =
               Issues.normalize_issue(missing_node, "owner", "repo", "sym").tracker_identity
    end

    # A shared `~/.aiur/config` that names no repo is the multi-repo case from
    # #2518: every GitHub call already resolves its repository from the
    # checkout's origin via `Config.repo/0`, so identity has to resolve the same
    # repository. When it did not, every issue normalized to an unjoinable
    # identity and every agent dispatch failed `:missing_tracker_identity`.
    test "uses the current checkout when repository configuration is absent" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: nil,
        tracker_label_prefix: "sym"
      )

      # Stub the shell boundary rather than reading the checkout's real remote,
      # so the assertion is the identity contract and not "this build has an
      # origin". `normalize_issue/4` has no option seam, so seed the resolved
      # value the production path reads.
      :persistent_term.put(@origin_cache_key, "acme/widgets")
      on_exit(fn -> :persistent_term.erase(@origin_cache_key) end)

      issue = %{"number" => 16, "node_id" => "I_kwDOIssue16", "labels" => []}
      identity = Issues.normalize_issue(issue, "acme", "widgets", "sym").tracker_identity

      assert %{status: :joinable, owner: "acme", repository: "widgets", identifier: "16"} = identity
      assert Aiur.TrackerIdentity.joinable?(identity)
    end

    # The auto-detected repository is still only a default: an explicitly
    # configured one must keep winning, or the trusted cross-repository setup
    # (daemon in checkout A tracking repo B) silently retargets.
    test "an explicitly configured repository still wins over a differing checkout origin" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "sym"
      )

      :persistent_term.put(@origin_cache_key, "acme/widgets")
      on_exit(fn -> :persistent_term.erase(@origin_cache_key) end)

      issue = %{"number" => 19, "node_id" => "I_kwDOIssue19", "labels" => []}

      assert %{status: :joinable, owner: "owner", repository: "repo"} =
               Issues.normalize_issue(issue, "owner", "repo", "sym").tracker_identity

      assert %{status: :unjoinable, reason: :repository_mismatch} =
               Issues.normalize_issue(issue, "acme", "widgets", "sym").tracker_identity
    end

    # The #2518 acceptance bar: identity must resolve for a repository whose
    # config lives OUTSIDE the global file. This drives the real chain —
    # `resolve_config_path/1` picks the repo-local file over a global one that
    # names a different repository, that file becomes active, and identity
    # resolves from it. Asserting `configured_repo/0` merely returns something
    # non-nil would pass against the bug; this does not.
    test "resolves identity from a repo-local config while a global config names another repository" do
      previous_path = Workflow.workflow_file_path()
      dir = Aiur.TestSupport.tmp_root!("aiur-2518-config-precedence")
      repo_local = Path.join([dir, "repo", ".aiur", "config"])
      global = Path.join([dir, "home", ".aiur", "config"])
      File.mkdir_p!(Path.dirname(repo_local))
      File.mkdir_p!(Path.dirname(global))

      # The global file names a DIFFERENT repository, so a fix that made the
      # global config win would resolve `global-org/global-repo` here.
      write_workflow_file!(global, tracker_kind: "github", tracker_repo: "global-org/global-repo", tracker_label_prefix: "sym")

      # The repo-local file carries no `tracker.github.repo` — the shared-config
      # shape from the report — so identity must come from the checkout.
      write_workflow_file!(repo_local, tracker_kind: "github", tracker_repo: nil, tracker_label_prefix: "sym")

      candidates = [repo_local, Path.join([dir, "repo", ".aiurconfig"]), global, Path.join([dir, "home", ".aiurconfig"])]
      assert Workflow.resolve_config_path(candidates) == repo_local

      :persistent_term.put(@origin_cache_key, "acme/widgets")
      Workflow.set_workflow_file_path(repo_local)

      on_exit(fn ->
        Workflow.set_workflow_file_path(previous_path)
        :persistent_term.erase(@origin_cache_key)
        Aiur.TestCleanup.rm_rf!(dir)
      end)

      issue = %{"number" => 20, "node_id" => "I_kwDOIssue20", "labels" => []}
      identity = Issues.normalize_issue(issue, "acme", "widgets", "sym").tracker_identity

      assert %{status: :joinable, owner: "acme", repository: "widgets", identifier: "20"} = identity
      assert Aiur.TrackerIdentity.joinable?(identity)
      refute identity.repository == "global-repo"
    end

    # This reads `configured_repo/0` through the shared `WorkflowStore`
    # singleton, which is why it was quarantined for #2397: under load the store
    # served the previous (valid) config for this path right after the malformed
    # write + `force_reload`, and CI run 32630000223 caught it returning a
    # `:joinable` identity with `owner/repo`. That mechanism is now pinned and
    # fixed — #2509 made the store derive the workflow and its freshness stamp
    # from a single read, so a write can no longer land between the two and
    # leave the pre-write config published. The tag is removed with it: a test
    # left excluded is not protected by the entry that was removed on its
    # behalf.
    test "marks malformed configured repositories explicitly nonjoinable" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo/extra",
        tracker_label_prefix: "sym"
      )

      issue = %{"number" => 17, "node_id" => "I_kwDOIssue17", "labels" => []}

      assert %{status: :unjoinable, reason: :invalid_configured_repository} =
               Issues.normalize_issue(issue, "owner", "repo", "sym").tracker_identity
    end

    test "marks closed issues with Closed state" do
      gh = %{
        "number" => 11,
        "title" => "Closed",
        "body" => nil,
        "html_url" => "https://github.com/owner/repo/issues/11",
        "labels" => [],
        "assignee" => nil,
        "state" => "closed",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")
      assert issue.state == "Closed"
    end

    test "marks paused issues" do
      gh = %{
        "number" => 12,
        "title" => "Paused",
        "body" => nil,
        "html_url" => "https://github.com/owner/repo/issues/12",
        "labels" => [%{"name" => "sym:paused"}, %{"name" => "sym:in-progress"}],
        "assignee" => nil,
        "state" => "open",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")
      assert issue.paused == true
      assert issue.state == "in-progress"
    end

    test "queued marker is not a state label" do
      for prefix <- ["agent", "aiur"] do
        gh = %{"number" => 19, "title" => "Queued", "state" => "open", "labels" => [%{"name" => "#{prefix}:todo"}, %{"name" => " #{String.upcase(prefix)}:QUEUED "}]}
        issue = Issues.normalize_issue(gh, "owner", "repo", prefix)
        assert issue.state_labels == ["todo"]
        assert issue.state == "todo"
        assert issue.queued == true
        assert Aiur.Issue.queued?(issue)
        refute Issues.normalize_issue(%{gh | "labels" => [%{"name" => "other:queued"}]}, "owner", "repo", prefix).queued
      end

      refute Aiur.Issue.queued?(%Aiur.Issue{})
      refute Aiur.Issue.queued?(nil)
    end

    test "marks parked issues and keeps the marker out of workflow state selection" do
      # #1971: `agent:parked` is an explicit operator-held marker. Even when a
      # real state label is present, the ticket must read as parked (so dispatch
      # and comment-driven rework refuse it), and the marker must never be
      # mistaken for a workflow state itself.
      gh = %{
        "number" => 19,
        "title" => "Parked",
        "body" => nil,
        "html_url" => "https://github.com/owner/repo/issues/19",
        "labels" => [%{"name" => "sym:parked"}, %{"name" => "sym:todo"}],
        "assignee" => nil,
        "state" => "open",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")

      assert issue.parked == true
      assert issue.state == "todo"
      assert "sym:parked" in issue.labels
      refute "parked" in issue.state_labels
    end

    test "resolves contradictory workflow state labels deterministically" do
      # A ticket carrying two `agent:*` state labels is a broken lifecycle state.
      # `extract_state` resolves it deterministically (todo wins; otherwise the
      # most-outstanding-work non-ci-wait label wins) so no consumer sees a nil
      # state and a stale `agent:ci-wait` can never outlive its CI run (#2366).
      gh = %{
        "number" => 18,
        "title" => "Contradictory labels",
        "labels" => [%{"name" => "sym:error"}, %{"name" => "sym:todo"}],
        "state" => "open"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")

      assert issue.state == "todo"
      assert issue.state_labels == ["error", "todo"]
    end

    test "resolves two real dispositions by most-outstanding-work precedence" do
      # Mirror of `DispatchPolicy.resolve_state_labels/1` (#2366): two labels
      # that both assert a real disposition resolve by the explicit precedence
      # order, not alphabetical order — `done` + `rework` is `rework`, never
      # `done`, so the heal never closes a ticket whose work is outstanding.
      for {labels, expected} <- [
            {["done", "rework"], "rework"},
            {["rework", "done"], "rework"},
            {["error", "rework"], "rework"},
            {["done", "in-progress"], "in-progress"},
            {["rework", "in-progress"], "rework"}
          ] do
        gh = %{
          "number" => 21,
          "title" => "Real dispositions",
          "labels" => Enum.map(labels, &%{"name" => "sym:#{&1}"}),
          "state" => "open"
        }

        assert Issues.extract_state(gh, Enum.map(labels, &"sym:#{&1}"), "sym") == expected
        assert Issues.normalize_issue(gh, "owner", "repo", "sym").state == expected
      end
    end

    test "resolves a ci-wait pair to the real disposition, never ci-wait" do
      # `ci-wait` is a transient sub-state and never wins a resolution: a
      # `ci-wait`+`rework` ticket is really rework, a `ci-wait`+`human-review`
      # ticket is really in review (#2366).
      for {labels, expected} <- [
            {["rework", "ci-wait"], "rework"},
            {["ci-wait", "human-review"], "human-review"},
            {["ci-wait"], "ci-wait"}
          ] do
        gh = %{"number" => 20, "title" => "ci-wait pair", "labels" => Enum.map(labels, &%{"name" => "sym:#{&1}"}), "state" => "open"}
        assert Issues.normalize_issue(gh, "owner", "repo", "sym").state == expected
      end
    end

    test "keeps the fallback marker out of workflow state selection" do
      gh = %{
        "number" => 13,
        "title" => "Fallback",
        "body" => nil,
        "html_url" => "https://github.com/owner/repo/issues/13",
        "labels" => [%{"name" => "sym:rate-limit-fallback"}, %{"name" => "sym:in-progress"}],
        "assignee" => nil,
        "state" => "open",
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-02T00:00:00Z"
      }

      issue = Issues.normalize_issue(gh, "owner", "repo", "sym")

      assert issue.state == "in-progress"
      assert "sym:rate-limit-fallback" in issue.labels
    end
  end
end
