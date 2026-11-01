defmodule Aiur.PrMerge.CommandTest do
  use ExUnit.Case, async: true
  alias Aiur.PrMerge
  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  setup do
    root = Path.join(System.tmp_dir!(), "merge-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    settings = %{
      workspace: %{root: Path.join(root, "agents")},
      merge_policy: %{ci: "wait", local_tests: "partial", main_watch: %{enabled: false}, attribution_scan: false, full_ci_labels: ["main-fix"], full_ci_paths: []},
      tracker: %{base_branch: "main", github: %{repo: "owner/repo", bot_account: "worker", github_app: %{account: "daemon[bot]"}, human_mergers: ["operator"]}}
    }

    opts = %{number: 1, reviewed_sha: @head, approve_body: nil, dry_run: false, inherited: []}
    {:ok, root: root, settings: settings, opts: opts}
  end

  defp deps(ctx, changes \\ []) do
    pid = self()

    [
      settings: fn -> {:ok, ctx.settings} end,
      cwd: ctx.root,
      agent_bin: nil,
      token: fn -> {:ok, "test-token"} end,
      api: fn method, path, body ->
        send(pid, {:api, method, path, body})
        response(method, path, body)
      end,
      merge_result: fn pr, _settings, _opts ->
        send(pid, {:premerge, pr.head})
        :ok
      end,
      notify: fn _record -> {:error, :down} end,
      log_root: Path.join(ctx.root, "logs"),
      puts: fn line -> send(pid, {:output, line}) end
    ]
    |> Keyword.merge(changes)
  end

  defp response("get", "user", _), do: {:ok, %{"login" => "operator", "type" => "User", "id" => 12}}

  defp response("get", "repos/owner/repo/pulls/1", _),
    do:
      {:ok,
       %{
         "node_id" => "PR_test",
         "user" => %{"id" => 99},
         "head" => %{"sha" => @head},
         "base" => %{"ref" => "main"},
         "state" => "open",
         "draft" => false,
         "title" => "Change",
         "body" => "",
         "labels" => [],
         "changed_files" => 1,
         "mergeable" => true
       }}

  defp response("post", "graphql", _) do
    {:ok,
     %{
       "data" => %{
         "repository" => %{
           "pullRequest" => %{
             "reviewDecision" => "APPROVED",
             "closingIssuesReferences" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}},
             "commits" => %{
               "nodes" => [
                 %{
                   "commit" => %{
                     "oid" => @head,
                     "statusCheckRollup" => %{
                       "contexts" => %{"nodes" => [%{"__typename" => "CheckRun", "name" => "lint", "status" => "COMPLETED", "conclusion" => "SUCCESS"}], "pageInfo" => %{"hasNextPage" => false}}
                     }
                   }
                 }
               ]
             }
           }
         }
       }
     }}
  end

  defp response("get", "repos/owner/repo/pulls/1/reviews?per_page=100&page=1", _),
    do: {:ok, [%{"id" => 1, "user" => %{"id" => 7}, "state" => "APPROVED", "commit_id" => @head, "submitted_at" => "2026-10-11T01:00:00Z"}]}

  defp response("get", "repos/owner/repo/rules/branches/main", _),
    do: {:ok, [%{"type" => "required_status_checks", "ruleset_id" => 1, "parameters" => %{"required_status_checks" => [%{"context" => "lint"}]}}]}

  defp response("get", "repos/owner/repo/branches/main/protection", _), do: {:error, "GitHub 404: Not Found"}
  defp response("get", "repos/owner/repo", _), do: {:ok, %{"permissions" => %{"admin" => false}}}
  defp response("get", "repos/owner/repo/rulesets/1", _), do: {:ok, %{"bypass_actors" => []}}
  defp response("get", "repos/owner/repo/pulls/1/files?per_page=100&page=1", _), do: {:ok, [%{"filename" => "lib/change.ex"}]}
  defp response("get", "repos/owner/repo/git/ref/heads/main", _), do: {:ok, %{"object" => %{"sha" => @base}}}
  defp response("post", "repos/owner/repo/pulls/1/reviews", body), do: {:ok, %{"state" => "APPROVED", "commit_id" => body.commit_id}}
  defp response("put", "repos/owner/repo/pulls/1/merge", _), do: {:ok, %{"merged" => true, "sha" => "merged-sha"}}

  defp next_write do
    receive do
      {:api, method, path, body} when method in ["post", "put"] and path != "graphql" -> {method, path, body}
    after
      0 -> flunk("no GitHub write observed after synchronous command completed")
    end
  end

  defp outputs(acc \\ []) do
    receive do
      {:output, line} -> outputs([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "approves at the head before squash merge and records success with daemon down", ctx do
    assert PrMerge.run(%{ctx.opts | approve_body: "Reviewed"}, deps(ctx)) == 0
    assert {"post", "repos/owner/repo/pulls/1/reviews", %{commit_id: @head, event: "APPROVE"}} = next_write()
    assert {"put", "repos/owner/repo/pulls/1/merge", %{sha: @head, merge_method: "squash", commit_title: "Change (#1)", commit_message: ""}} = next_write()
    [record] = ctx.root |> Path.join("logs/merges.ndjson") |> Aiur.Jsonl.stream() |> Enum.to_list()
    assert record["sha"] == @head
    assert record["merged_sha"] == "merged-sha"
    assert record["actor"] == "operator"
    assert record["pending_count"] == 0
    assert_received {:output, "WARNING merged, but daemon event delivery failed"}
  end

  test "dry run runs premerge and fresh facts with no approval, merge or ledger", ctx do
    assert PrMerge.run(%{ctx.opts | dry_run: true, approve_body: "Reviewed"}, deps(ctx)) == 0
    assert_received {:premerge, @head}
    refute_received {:api, "put", _, _}
    refute_received {:api, "post", "repos/owner/repo/pulls/1/reviews", _}
    refute File.exists?(Path.join(ctx.root, "logs/merges.ndjson"))
  end

  test "agent refusal happens before credentials or network", ctx do
    token = fn -> flunk("must not read operator keyring") end
    api = fn _, _, _ -> flunk("must not access network") end
    assert PrMerge.run(ctx.opts, deps(ctx, agent_bin: "agent", token: token, api: api)) == 2
  end

  test "GitHub merge refusal remains a tool error with its message", ctx do
    api = fn method, path, body -> if method == "put", do: {:error, "GitHub 405: bypass missing"}, else: response(method, path, body) end
    assert PrMerge.run(ctx.opts, deps(ctx, api: api)) == 1
    assert Enum.any?(outputs(), &(&1 =~ "aiur pr merge: deliver failed: GitHub 405: bypass missing" and &1 =~ "merge outcome may be unknown"))
  end

  test "a failed check arriving during premerge prevents the write", ctx do
    key = make_ref()

    api = fn method, path, body ->
      result = response(method, path, body)

      if path == "graphql" and Process.get(key) do
        {:ok, map} = result
        {:ok, put_in(map, ["data", "repository", "pullRequest", "commits", "nodes", Access.at(0), "commit", "statusCheckRollup", "contexts", "nodes", Access.at(0), "conclusion"], "FAILURE")}
      else
        result
      end
    end

    premerge = fn _, _, _ ->
      Process.put(key, true)
      :ok
    end

    assert PrMerge.run(ctx.opts, deps(ctx, api: api, merge_result: premerge)) == 2
    assert_received {:output, "REFUSE CI failed: lint"}
    refute File.exists?(Path.join(ctx.root, "logs/merges.ndjson"))
  end

  test "a reported red integration branch is informational", ctx do
    settings = put_in(ctx.settings, [:merge_policy, :main_watch, :enabled], true)
    ctx = %{ctx | settings: settings}
    state = fn -> %{"status" => "red", "red_since" => "yesterday", "fixer_identifier" => "42"} end
    assert PrMerge.run(%{ctx.opts | dry_run: true}, deps(ctx, watcher_state: state)) == 0
    assert_received {:output, "NOTE integration branch is red since yesterday (fixer 42)"}
  end

  test "truncated check observations fail closed", ctx do
    api = fn method, path, body ->
      result = response(method, path, body)

      if path == "graphql" do
        {:ok, map} = result
        {:ok, put_in(map, ["data", "repository", "pullRequest", "commits", "nodes", Access.at(0), "commit", "statusCheckRollup", "contexts", "pageInfo", "hasNextPage"], true)}
      else
        result
      end
    end

    assert PrMerge.run(ctx.opts, deps(ctx, api: api)) == 1
    refute_received {:premerge, _}
  end

  test "raised failures identify every merge phase and return status 1", ctx do
    phases = [:settings, :identity_guard, :token, :viewer, :observe, :facts, :merge_result, :approve, :deliver, :record]

    Enum.each(phases, fn phase ->
      reason = "injected failure at #{phase}"
      step = fn current, callback -> if current == phase, do: raise(reason), else: callback.() end
      assert PrMerge.run(%{ctx.opts | approve_body: "Reviewed"}, deps(ctx, step: step)) == 1
      phase_outputs = outputs()
      assert Enum.any?(phase_outputs, &(&1 =~ "aiur pr merge: #{phase} failed: #{reason}"))
      outcome = if phase in [:deliver, :record], do: "merge outcome may be unknown", else: "nothing was merged"
      assert Enum.any?(phase_outputs, &String.contains?(&1, outcome))
    end)
  end

  test "raised exception is logged with stacktrace and token-shaped text is redacted", ctx do
    token = "ghp_123456789012345678901234567890123456"
    step = fn current, callback -> if current == :merge_result, do: raise("failed with #{token}"), else: callback.() end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert PrMerge.run(ctx.opts, deps(ctx, step: step)) == 1
      end)

    assert log =~ "aiur pr merge: merge_result failed"
    assert log =~ "command_test.exs"
    assert log =~ "[REDACTED]"
    refute log =~ token
    assert Enum.all?(outputs(), &(not String.contains?(&1, token)))
    [failure] = ctx.root |> Path.join("logs/merges.ndjson") |> Aiur.Jsonl.stream() |> Enum.to_list()
    assert failure["failed_step"] == "merge_result"
    assert failure["outcome"] == "not_merged"
    refute failure["error"] =~ token
  end

  test "a record failure after delivery keeps the unknown outcome warning", ctx do
    step = fn current, callback -> if current == :record, do: raise("ledger failed"), else: callback.() end

    assert PrMerge.run(ctx.opts, deps(ctx, step: step)) == 1
    phase_outputs = outputs()
    assert Enum.any?(phase_outputs, &(&1 =~ "aiur pr merge: record failed: ledger failed" and &1 =~ "merge outcome may be unknown"))
    [failure] = ctx.root |> Path.join("logs/merges.ndjson") |> Aiur.Jsonl.stream() |> Enum.to_list()
    assert failure["outcome"] == "unknown"
  end

  test "a ledger failure after observing an existing merge preserves the known outcome", ctx do
    api = fn method, path, body ->
      case {method, path} do
        {"get", "repos/owner/repo/pulls/1"} ->
          {:ok, raw} = response(method, path, body)

          {:ok,
           Map.merge(raw, %{
             "state" => "closed",
             "merged" => true,
             "merge_commit_sha" => "confirmed-merge-sha",
             "merged_by" => %{"login" => "operator"},
             "merged_at" => DateTime.utc_now() |> DateTime.to_iso8601()
           })}

        _ ->
          response(method, path, body)
      end
    end

    step = fn current, callback -> if current == :record, do: raise("ledger failed"), else: callback.() end

    assert PrMerge.run(ctx.opts, deps(ctx, api: api, step: step)) == 1
    assert Enum.any?(outputs(), &(&1 =~ "aiur pr merge: record failed: ledger failed" and &1 =~ "GitHub confirms the PR is already merged"))
    [failure] = ctx.root |> Path.join("logs/merges.ndjson") |> Aiur.Jsonl.stream() |> Enum.to_list()
    assert failure["outcome"] == "merged"
  end

  test "ledger directory setup failure reports the record phase before delivery", ctx do
    step = fn current, callback -> if current == :record_setup, do: raise("directory setup failed"), else: callback.() end

    assert PrMerge.run(ctx.opts, deps(ctx, step: step)) == 1
    assert Enum.any?(outputs(), &(&1 =~ "aiur pr merge: record failed: directory setup failed" and &1 =~ "nothing was merged"))
    [failure] = ctx.root |> Path.join("logs/merges.ndjson") |> Aiur.Jsonl.stream() |> Enum.to_list()
    assert failure["failed_step"] == "record"
    assert failure["outcome"] == "not_merged"
  end
end
