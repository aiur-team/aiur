defmodule Aiur.PrMerge.QueueCommandTest do
  use ExUnit.Case, async: true
  alias Aiur.PrMerge
  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  setup do
    root = Path.join(System.tmp_dir!(), "queue-merge-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    settings = %{
      workspace: %{root: Path.join(root, "agents")},
      merge_policy: %{ci: "wait", local_tests: "partial", main_watch: %{enabled: false}, attribution_scan: false, full_ci_labels: [], full_ci_paths: []},
      tracker: %{base_branch: "main", github: %{repo: "owner/repo", bot_account: "worker", github_app: %{account: "daemon[bot]"}, human_mergers: ["operator"]}}
    }

    opts = %{number: 1, reviewed_sha: @head, approve_body: nil, dry_run: false, inherited: []}
    {:ok, root: root, settings: settings, opts: opts}
  end

  defp run(ctx, changes \\ []) do
    key = make_ref()
    state = %{queue: true, approved: true, approval_effect: true, merged: false, author: 99, stale_after_approval: false, approval_posted: false} |> Map.merge(Map.new(changes))
    Process.put(key, state)
    pid = self()

    deps = [
      settings: fn -> {:ok, ctx.settings} end,
      cwd: ctx.root,
      agent_bin: nil,
      token: fn -> {:ok, "test"} end,
      api: fn method, path, body ->
        send(pid, {:api, method, path, body})
        response(key, method, path, body)
      end,
      merge_result: fn _, _, _ ->
        send(pid, :premerge)
        :ok
      end,
      notify: fn record ->
        send(pid, {:notify, record})
        :ok
      end,
      log_root: Path.join(ctx.root, "logs"),
      puts: fn line -> send(pid, {:output, line}) end
    ]

    PrMerge.run(ctx.opts, deps)
  end

  defp response(_key, "get", "user", _), do: {:ok, %{"login" => "operator", "type" => "User", "id" => 12}}

  defp response(key, "get", "repos/owner/repo/pulls/1", _) do
    state = Process.get(key)

    {:ok,
     %{
       "node_id" => "PR_1",
       "user" => %{"id" => state.author},
       "head" => %{"sha" => current_head(state)},
       "base" => %{"ref" => "main", "sha" => @base},
       "state" => state[:raw_state] || if(state.merged, do: "closed", else: "open"),
       "draft" => false,
       "title" => "Change",
       "body" => "",
       "labels" => [],
       "changed_files" => 0,
       "mergeable" => true,
       "merged" => state.merged,
       "merge_commit_sha" => "merge-sha",
       "merged_by" => %{"login" => "github-merger"},
       "merged_at" => "2026-10-11T00:00:00Z"
     }}
  end

  defp response(key, "post", "graphql", %{variables: %{input: input}}) do
    state = Process.get(key)

    if state[:enqueue_error] do
      {:ok, %{"errors" => [%{"message" => "head changed"}], "data" => %{"enqueuePullRequest" => nil}}}
    else
      {:ok,
       %{
         "data" => %{
           "enqueuePullRequest" => %{
             "mergeQueueEntry" => %{
               "id" => "MQ_1",
               "pullRequest" => %{"id" => input.pullRequestId, "headRefOid" => if(state[:wrong_queue_head], do: String.duplicate("c", 40), else: input.expectedHeadOid)}
             }
           }
         }
       }}
    end
  end

  defp response(key, "post", "graphql", _) do
    {:ok,
     %{
       "data" => %{
         "repository" => %{
           "pullRequest" => %{
             "reviewDecision" => "APPROVED",
             "closingIssuesReferences" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}},
             "commits" => %{"nodes" => [%{"commit" => %{"oid" => current_head(Process.get(key)), "statusCheckRollup" => nil}}]}
           }
         }
       }
     }}
  end

  defp response(key, "get", "repos/owner/repo/pulls/1/reviews?per_page=100&page=1", _) do
    state = Process.get(key)
    reviews = if state.approved, do: [%{"id" => 1, "state" => "APPROVED", "commit_id" => @head, "user" => %{"id" => 22}, "submitted_at" => "2026-10-11T00:00:00Z"}], else: []
    {:ok, reviews}
  end

  defp response(key, "get", "repos/owner/repo/rules/branches/main", _) do
    state = Process.get(key)

    cond do
      state[:invalid_rules] -> {:ok, [%{}]}
      state[:invalid_checks_rule] -> {:ok, [%{"type" => "required_status_checks"}]}
      state[:rules_unavailable] -> {:error, "branch rules unavailable"}
      true -> {:ok, if(state.queue, do: [%{"type" => "merge_queue"}], else: [])}
    end
  end

  defp response(_key, "get", "repos/owner/repo/branches/main/protection", _), do: {:error, "GitHub 404: absent"}
  defp response(_key, "get", "repos/owner/repo", _), do: {:ok, %{"permissions" => %{"admin" => true}}}
  defp response(_key, "get", "repos/owner/repo/pulls/1/files?per_page=100&page=1", _), do: {:ok, []}
  defp response(_key, "get", "repos/owner/repo/git/ref/heads/main", _), do: {:ok, %{"object" => %{"sha" => @base}}}

  defp response(key, "post", "repos/owner/repo/pulls/1/reviews", body) do
    state = Process.get(key)
    Process.put(key, %{state | approved: state.approval_effect, approval_posted: true})
    {:ok, %{"state" => "APPROVED", "commit_id" => body.commit_id}}
  end

  defp response(_key, "put", "repos/owner/repo/pulls/1/merge", _), do: {:ok, %{"merged" => true, "sha" => "merge-sha"}}

  defp current_head(%{stale_after_approval: true, approval_posted: true}), do: String.duplicate("c", 40)
  defp current_head(_state), do: @head

  defp ledger(ctx), do: ctx.root |> Path.join("logs/merges.ndjson") |> Aiur.Jsonl.stream() |> Enum.to_list()

  test "queue base enqueues pinned head and records enqueue without merged event", ctx do
    assert run(ctx) == 0
    assert_received {:api, "post", "graphql", %{variables: %{input: %{pullRequestId: "PR_1", expectedHeadOid: @head}}}}
    refute_received {:api, "put", _, _}
    refute_received {:notify, _}
    assert [%{"state" => "enqueued", "sha" => @head, "queue_entry" => "MQ_1"}] = ledger(ctx)
    assert_received {:output, "ENQUEUED #1 " <> _}
  end

  test "nonqueue base retains pinned squash merge", ctx do
    assert run(ctx, queue: false) == 0
    assert_received {:api, "put", "repos/owner/repo/pulls/1/merge", %{sha: @head, merge_method: "squash"}}
    assert_received {:notify, %{state: "merged", merged_sha: "merge-sha"}}
  end

  test "queue error neither merges nor records success", ctx do
    assert run(ctx, enqueue_error: true) == 1
    refute_received {:api, "put", _, _}
    refute_received {:notify, _}
    refute File.exists?(Path.join(ctx.root, "logs/merges.ndjson"))
  end

  test "planned approval must be observed before enqueue", ctx do
    ctx = %{ctx | opts: %{ctx.opts | approve_body: "Reviewed"}}
    assert run(ctx, approved: false) == 0
    assert_received {:api, "post", "repos/owner/repo/pulls/1/reviews", %{commit_id: @head}}
    assert_received {:api, "post", "graphql", %{variables: %{input: %{expectedHeadOid: @head}}}}
  end

  test "approval response alone cannot authorize enqueue", ctx do
    ctx = %{ctx | opts: %{ctx.opts | approve_body: "Reviewed"}}
    assert run(ctx, approved: false, approval_effect: false) == 2
    refute_received {:api, "post", "graphql", %{variables: %{input: _}}}
    refute_received {:api, "put", _, _}
  end

  test "dry run cannot assume planned approval exists", ctx do
    ctx = %{ctx | opts: %{ctx.opts | dry_run: true, approve_body: "Reviewed"}}
    assert run(ctx, approved: false) == 2
    refute_received {:api, "post", "repos/owner/repo/pulls/1/reviews", _}
  end

  test "self approval refuses before posting", ctx do
    ctx = %{ctx | opts: %{ctx.opts | approve_body: "Reviewed"}}
    assert run(ctx, author: 12, approved: false) == 2
    refute_received {:api, "post", "repos/owner/repo/pulls/1/reviews", _}
  end

  test "observed merged invocation records actual merger without enqueue or premerge", ctx do
    assert run(ctx, merged: true) == 0
    assert [%{"state" => "merged", "actor" => "github-merger", "merged_sha" => "merge-sha"}] = ledger(ctx)
    assert_received {:notify, %{actor: "github-merger", state: "merged"}}
    refute_received :premerge
    refute_received {:api, "post", _, _}
    refute_received {:api, "put", _, _}
  end

  test "observed merge still requires reviewed head pin", ctx do
    ctx = %{ctx | opts: %{ctx.opts | reviewed_sha: String.duplicate("c", 40)}}
    assert run(ctx, merged: true) == 2
    refute_received {:notify, _}
    refute File.exists?(Path.join(ctx.root, "logs/merges.ndjson"))
  end

  test "observed merged dry run writes no ledger or event", ctx do
    ctx = %{ctx | opts: %{ctx.opts | dry_run: true}}
    assert run(ctx, merged: true) == 0
    refute_received {:notify, _}
    refute File.exists?(Path.join(ctx.root, "logs/merges.ndjson"))
  end

  test "unknown or malformed branch rules refuse rather than using direct merge", ctx do
    assert run(ctx, rules_unavailable: true) == 1
    assert run(ctx, invalid_rules: true) == 1
    assert run(ctx, invalid_checks_rule: true) == 1
    refute_received {:api, "put", _, _}
    refute_received {:api, "post", "graphql", %{variables: %{input: _}}}
  end

  test "head moving after approval refuses every delivery route", ctx do
    ctx = %{ctx | opts: %{ctx.opts | approve_body: "Reviewed"}}
    assert run(ctx, approved: false, stale_after_approval: true) == 2
    assert_received {:api, "post", "repos/owner/repo/pulls/1/reviews", %{commit_id: @head}}
    refute_received {:api, "post", "graphql", %{variables: %{input: _}}}
    refute_received {:api, "put", _, _}
  end

  test "queue acknowledgement must confirm the pinned head", ctx do
    assert run(ctx, wrong_queue_head: true) == 1
    refute_received {:api, "put", _, _}
    refute_received {:notify, _}
    refute File.exists?(Path.join(ctx.root, "logs/merges.ndjson"))
  end

  test "inconsistent merged but open observation records nothing", ctx do
    assert run(ctx, merged: true, raw_state: "open") == 1
    refute_received {:notify, _}
    refute File.exists?(Path.join(ctx.root, "logs/merges.ndjson"))
  end
end
