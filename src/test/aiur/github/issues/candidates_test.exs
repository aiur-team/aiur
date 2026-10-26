defmodule Aiur.GitHub.Issues.CandidatesTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Client
  alias Aiur.GitHub.DispatchAuthorization
  alias Aiur.GitHub.Issues
  alias Aiur.Issue
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State

  @token_cache_key {Aiur.GitHub.Access.Token, :resolved_token}

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

  describe "fetch_candidate_issues/1" do
    test "does not retain a foreign-prefix ticket as a degenerate repair candidate" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo"]
      )

      foreign_ticket = %{
        "number" => 5895,
        "title" => "Other instance ticket",
        "body" => nil,
        "html_url" => "https://github.com/owner/repo/issues/5895",
        "labels" => [%{"name" => " NUC:todo "}],
        "assignee" => nil,
        "created_at" => "2026-10-22T00:00:00Z",
        "updated_at" => "2026-10-22T00:00:00Z"
      }

      request_fun = fn %{url: url} ->
        assert url == "https://api.github.com/repos/owner/repo/issues?state=open&per_page=100"
        {:ok, %{status: 200, headers: [], body: [foreign_ticket]}}
      end

      assert {:ok, [], _cache} = Issues.fetch_candidate_issues_conditional(%{}, request_fun: request_fun)
    end

    test "complete paginated polls record all labels with no extra requests" do
      alias Aiur.GitHub.OpenIssueSnapshot
      OpenIssueSnapshot.reset()
      on_exit(fn -> OpenIssueSnapshot.reset() end)
      Phoenix.PubSub.subscribe(Aiur.PubSub, "tracker:open_issues")
      Aiur.TestScopeGuard.put_ticket_scope!("7")
      parent = self()
      base_url = "https://api.github.com/repos/owner/repo/issues?state=open&per_page=100"
      second_url = base_url <> "&page=2"

      issue = fn number ->
        %{"number" => number, "title" => "Open issue", "labels" => [%{"name" => "AGENT:QUEUED"}, %{"name" => "sym:done"}], "updated_at" => "2026-10-06T00:00:00Z"}
      end

      request_fun = fn request ->
        send(parent, {:list_request, request.url})

        cond do
          Map.has_key?(request, :etag) -> {:ok, %{status: 304, headers: []}}
          request.url == base_url -> {:ok, %{status: 200, headers: [{"etag", "page-one"}, {"link", "<#{second_url}>; rel=\"next\""}], body: [issue.(7)]}}
          request.url == second_url -> {:ok, %{status: 200, headers: [{"etag", "page-two"}], body: [issue.(8)]}}
          true -> flunk("unexpected request: #{request.url}")
        end
      end

      expected = Map.new(["7", "8"], &{&1, %{labels: ["agent:queued", "sym:done"], updated_at: ~U[2026-10-06 00:00:00Z]}})
      assert {:ok, []} = Issues.fetch_candidate_issues(request_fun: request_fun)
      assert_received {:open_issues_recorded, first_time}
      assert {:ok, ^expected, labels_from} = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
      assert labels_from <= first_time
      assert_received {:list_request, ^base_url}
      assert_received {:list_request, ^second_url}
      refute_received {:list_request, _}
      assert {:ok, [], cache} = Issues.fetch_candidate_issues_conditional(%{}, request_fun: request_fun)
      assert_received {:open_issues_recorded, _}
      assert_received {:list_request, ^base_url}
      assert_received {:list_request, ^second_url}
      refute_received {:list_request, _}
      assert {:ok, [], _} = Issues.fetch_candidate_issues_conditional(cache, request_fun: request_fun)
      assert_received {:open_issues_recorded, cached_time}
      assert {:ok, ^expected, cached_labels_from} = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
      assert_received {:list_request, ^base_url}
      assert_received {:list_request, ^second_url}
      refute_received {:list_request, _}

      assert cached_labels_from <= cached_time

      failed_page = fn request ->
        if request.url == base_url, do: request_fun.(request), else: {:error, :timeout}
      end

      assert {:error, _} = Issues.fetch_candidate_issues_conditional(%{}, request_fun: failed_page)
      assert {:ok, ^expected, ^cached_labels_from} = OpenIssueSnapshot.fetch_labels("owner", "repo", 60_000)
      refute_received {:open_issues_recorded, _}
    end

    test "pinned test scope skips out-of-scope provenance before dispatch authorization" do
      Aiur.TestScopeGuard.put_ticket_scope!("99")

      # Keep dispatch authorization independent of the shared CODEOWNERS
      # snapshot; this test is about pinned-scope filtering, not trust loading.
      write_workflow_file_atomic!(
        Workflow.workflow_file_path(),
        """
        tracker:
          kind: github
          active_states: [todo]
          github:
            repo: owner/repo
            label_prefix: sym
            allowed_users: [its-everdred]
        """
      )

      :ok = WorkflowStore.force_reload()

      issue = fn number ->
        %{
          "number" => number,
          "node_id" => "I_kwDOIssue#{number}",
          "title" => "Issue #{number}",
          "body" => nil,
          "html_url" => "https://github.com/owner/repo/issues/#{number}",
          "labels" => [%{"name" => "sym:todo"}],
          "assignee" => nil,
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-02T00:00:00Z"
        }
      end

      parent = self()

      request_fun = fn %{url: url} ->
        if String.contains?(url, "/timeline") do
          send(parent, {:timeline_requested, url})

          {:ok,
           %{
             status: 200,
             headers: [],
             body: [
               %{
                 "id" => 1,
                 "event" => "labeled",
                 "label" => %{"name" => "sym:todo"},
                 "actor" => %{"login" => "its-everdred"},
                 "created_at" => "2026-01-01T00:00:00Z"
               }
             ]
           }}
        else
          assert url == "https://api.github.com/repos/owner/repo/issues?state=open&per_page=100"
          {:ok, %{status: 200, headers: [], body: [issue.(2413), issue.(99)]}}
        end
      end

      assert {:ok, [%Issue{identifier: "99", dispatch_authorized?: true}]} =
               Client.fetch_candidate_issues(request_fun: request_fun)

      assert_received {:timeline_requested, "https://api.github.com/repos/owner/repo/issues/99/timeline?per_page=50"}
      refute_received {:timeline_requested, "https://api.github.com/repos/owner/repo/issues/2413/timeline?per_page=50"}

      DispatchAuthorization.clear_cache()

      assert {:ok, [%Issue{identifier: "99", dispatch_authorized?: true}], _cache} =
               Client.fetch_candidate_issues_conditional(%{}, request_fun: request_fun)

      assert_received {:timeline_requested, "https://api.github.com/repos/owner/repo/issues/99/timeline?per_page=50"}
      refute_received {:timeline_requested, "https://api.github.com/repos/owner/repo/issues/2413/timeline?per_page=50"}
    end

    # Guards the too-large clause in `conditional_get/4`: with it reverted the
    # collector's empty-bodied 200 falls through to `github_status_error/1` and
    # this returns the bare `%{status: 200}` detail with no `:reason`.
    test "reports an over-limit open-issue list as too large, not as a bare 200" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "sym",
        tracker_active_states: ["Todo"]
      )

      request_fun = fn request ->
        assert request.url == "https://api.github.com/repos/owner/repo/issues?state=open&per_page=100"
        {:ok, %{status: 200, headers: [], body: "", private: %{aiur_response_too_large: true}}}
      end

      assert {:error, {:github, :http, %{status: 200, reason: :response_too_large, max_response_bytes: 16_777_216}}} =
               Issues.fetch_candidate_issues_conditional(%{}, request_fun: request_fun)
    end

    test "revalidates one authoritative list and reuses it only on 304" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "sym",
        tracker_active_states: ["Todo", "In Progress"]
      )

      issue = fn number, state ->
        labels = if is_binary(state), do: [%{"name" => "sym:#{state}"}], else: []

        %{
          "number" => number,
          "title" => "Mutable label",
          "body" => nil,
          "html_url" => "https://github.com/owner/repo/issues/#{number}",
          "labels" => labels,
          "assignee" => nil,
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-02T00:00:00Z"
        }
      end

      stale_page = [issue.(42, "in-progress"), issue.(43, "done"), issue.(44, nil)]
      fresh_page = [issue.(42, "todo"), issue.(43, "done"), issue.(44, nil)]
      {:ok, list_step} = Agent.start_link(fn -> 0 end)

      request_fun = fn request ->
        if String.contains?(request.url, "/timeline?per_page=") do
          {:ok, %{status: 200, headers: [], body: []}}
        else
          assert request.url == "https://api.github.com/repos/owner/repo/issues?state=open&per_page=100"
          # The open-issue list is bound by its own, larger cap (#2140) sized to
          # the endpoint's ceiling — one full page of maximal bodies — so a
          # spec-heavy backlog does not truncate (#2533).
          assert request.max_response_bytes == 16_777_216

          Agent.get_and_update(list_step, fn
            0 ->
              refute Map.has_key?(request, :etag)
              {{:ok, %{status: 200, headers: [{"etag", "v1"}], body: stale_page}}, 1}

            1 ->
              assert request.etag == "v1"
              {{:ok, %{status: 200, headers: [{"etag", "v2"}], body: fresh_page}}, 2}

            2 ->
              assert request.etag == "v2"
              {{:ok, %{status: 304}}, 3}
          end)
        end
      end

      # The conditional path (the orchestrator's dispatch poll) partitions
      # rather than discards: the zero-label issue 44 is returned alongside the
      # authorized dispatch candidate 42 so the repair pass can heal it (#2420).
      # The terminal-labelled issue 43 is still dropped.
      assert {:ok, issues, cache} =
               Issues.fetch_candidate_issues_conditional(%{}, request_fun: request_fun)

      assert Enum.map(issues, & &1.id) == ["42", "44"]
      assert Enum.find(issues, &(&1.id == "42")).state == "in-progress"
      assert Enum.find(issues, &(&1.id == "44")).state_labels == []

      assert {:ok, issues, cache} =
               Issues.fetch_candidate_issues_conditional(cache, request_fun: request_fun)

      assert Enum.map(issues, & &1.id) == ["42", "44"]
      assert Enum.find(issues, &(&1.id == "42")).state == "todo"

      assert {:ok, issues, _cache} =
               Issues.fetch_candidate_issues_conditional(cache, request_fun: request_fun)

      assert Enum.map(issues, & &1.id) == ["42", "44"]

      assert Agent.get(list_step, & &1) == 3
    end

    test "fresh non-dispatchable states survive repeated polls and next-poll zero-label healing" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "sym",
        tracker_active_states: ["todo", "in-progress"]
      )

      for target <- ~w(ci-wait human-review error) do
        number = System.unique_integer([:positive])
        identifier = to_string(number)
        previous = %Issue{id: identifier, identifier: identifier, state: "in-progress", state_labels: ["in-progress"]}
        state = %State{last_polled_issues: %{identifier => previous}}
        {:ok, reads} = Agent.start_link(fn -> 0 end)

        request_fun = fn request ->
          # Neither label-evidence polls nor their synchronization need a timeline or by-id read.
          assert request.url == "https://api.github.com/repos/owner/repo/issues?state=open&per_page=100"
          step = Agent.get_and_update(reads, &{&1, &1 + 1})
          labels = if step < 2, do: [%{"name" => "sym:#{target}"}], else: []

          {:ok,
           %{
             status: 200,
             headers: [{"etag", "#{target}-#{step}"}],
             body: [%{"number" => number, "title" => "Fresh lifecycle evidence", "state" => "open", "labels" => labels}]
           }}
        end

        sync = fn state, issues ->
          IssueSync.sync_polled_issue_state(
            state,
            issues,
            fn ids -> flunk("unexpected per-issue fetch: #{inspect(ids)}") end,
            fn _, _ -> :ok end,
            MapSet.new(["done"]),
            fn _ -> :ok end,
            fn _, _ -> :ok end
          )
        end

        assert {:ok, [fresh] = issues, cache} = Client.fetch_candidate_issues_conditional(%{}, request_fun: request_fun)
        assert fresh.state == target
        refute fresh.dispatch_authorized?
        state = sync.(state, issues)
        assert state.last_polled_issues[identifier].state == target

        assert {:ok, [fresh] = issues, cache} = Client.fetch_candidate_issues_conditional(cache, request_fun: request_fun)
        assert fresh.state == target
        state = sync.(state, issues)
        assert state.last_polled_issues[identifier].state == target

        assert {:ok, [missing], _cache} = Client.fetch_candidate_issues_conditional(cache, request_fun: request_fun)
        assert missing.state_labels == []
        parent = self()

        {_, [healed]} =
          IssueSync.reconcile_contradictory_state_labels(state, [missing], fn id, restored ->
            send(parent, {:heal, id, restored})
            :ok
          end)

        assert_received {:heal, ^identifier, ^target}
        assert healed.state_labels == [target]
        assert Agent.get(reads, & &1) == 3
      end
    end

    test "the conditional path surfaces degenerate tickets for repair but excludes pull requests" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "sym",
        tracker_active_states: ["todo", "in-progress"]
      )

      issue = fn number, labels ->
        %{
          "number" => number,
          "title" => "Issue #{number}",
          "body" => nil,
          "html_url" => "https://github.com/owner/repo/issues/#{number}",
          "labels" => labels,
          "assignee" => nil,
          "created_at" => "2026-01-01T00:00:00Z",
          "updated_at" => "2026-01-02T00:00:00Z"
        }
      end

      page = [
        issue.(50, [%{"name" => "sym:todo"}]),
        issue.(51, []),
        issue.(52, [%{"name" => "sym:in-progress"}, %{"name" => "sym:rework"}]),
        Map.put(issue.(53, []), "pull_request", %{"url" => "https://api.github.com/repos/owner/repo/pulls/53"})
      ]

      {:ok, list_step} = Agent.start_link(fn -> 0 end)

      # Dispatch authorization needs a labeled timeline event for the
      # dispatchable candidate; the degenerate tickets must not be authorized.
      request_fun = fn request ->
        if String.contains?(request.url, "/timeline?per_page=") do
          labeled_event = %{
            "id" => 1,
            "event" => "labeled",
            "label" => %{"name" => "sym:todo"},
            "actor" => %{"login" => "its-everdred"},
            "created_at" => "2026-01-01T00:00:00Z"
          }

          {:ok, %{status: 200, headers: [], body: [labeled_event]}}
        else
          assert request.url == "https://api.github.com/repos/owner/repo/issues?state=open&per_page=100"

          Agent.get_and_update(list_step, fn
            0 -> {{:ok, %{status: 200, headers: [{"etag", "v1"}], body: page}}, 1}
            1 -> {{:ok, %{status: 304}}, 2}
          end)
        end
      end

      assert {:ok, issues, cache} =
               Issues.fetch_candidate_issues_conditional(%{}, request_fun: request_fun)

      ids = Enum.map(issues, & &1.id)
      assert "50" in ids
      assert "51" in ids
      assert "52" in ids
      refute "53" in ids

      # The zero-label (51) and contradictory-label (52) tickets keep their
      # degenerate state_labels so the orchestrator's repair pass can heal
      # them; only the dispatch candidate (50) is authorized.
      assert Enum.find(issues, &(&1.id == "51")).state_labels == []
      assert Enum.find(issues, &(&1.id == "52")).state_labels == ["in-progress", "rework"]
      assert Enum.find(issues, &(&1.id == "50")).dispatch_authorized?
      refute Enum.find(issues, &(&1.id == "51")).dispatch_authorized?
      refute Enum.find(issues, &(&1.id == "52")).dispatch_authorized?

      assert {:ok, cached_issues, _cache} =
               Issues.fetch_candidate_issues_conditional(cache, request_fun: request_fun)

      assert Enum.map(cached_issues, & &1.id) == ids
      assert Agent.get(list_step, & &1) == 2
    end
  end
end
