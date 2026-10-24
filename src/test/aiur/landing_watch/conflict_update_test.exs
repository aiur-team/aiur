defmodule Aiur.LandingWatch.ConflictUpdateTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch
  alias Aiur.LandingWatch.{ConflictUpdate, Journal}

  @green %{"id" => 60, "name" => "ci gate", "status" => "completed", "conclusion" => "success", "check_suite" => %{"id" => 101}}
  @refused {:error, {:github, :http, %{status: 422}}}

  test "a clean update-branch merges main and re-arms auto-merge with no rework turn, once per main SHA" do
    parent = self()
    opts = cycle_opts(parent, conflicting(), {:ok, %{}})

    assert :ok = LandingWatch.poll(opts)
    assert_received {:update_branch, 17, "head-sha"}
    assert_received {:auto_merge, "PR_node"}
    refute_received {:transition, _, _, _}
    refute_received {:comment, _, _}
    refute_received {:withdraw, _}

    # GitHub's merge commit has not landed yet: the same head on the same main is held, not re-updated or reworked.
    assert :ok = LandingWatch.poll(opts)
    refute_received {:update_branch, _, _}
    refute_received {:transition, _, _, _}

    assert :ok = LandingWatch.poll(Keyword.put(opts, :observe_fun, fn _ -> {:ok, [%{conflicting() | base_oid: "main-2"}]} end))
    assert_received {:update_branch, 17, "head-sha"}
  end

  test "a conflict found by the pre-enqueue read is updated the same way" do
    parent = self()
    observation = %{conflicting() | mergeable: "MERGEABLE", merge_state_status: "CLEAN"}
    opts = cycle_opts(parent, observation, {:ok, %{}}) |> Keyword.put(:revalidate_fun, fn 17, "head-sha", _ -> {:error, :merge_conflict} end)

    assert :ok = LandingWatch.poll(opts)
    assert_received {:update_branch, 17, "head-sha"}
    refute_received {:enqueued, _}
    refute_received {:transition, _, _, _}
  end

  test "a refused update-branch routes to rebase-only rework naming the conflicting files" do
    parent = self()
    opts = cycle_opts(parent, conflicting(), @refused)

    assert :ok = LandingWatch.poll(opts)
    assert_received {:update_branch, 17, "head-sha"}
    assert_received {:transition, "17", "rework", _}
    assert_received {:comment, "17", body}
    assert body =~ "Rebase only"
    assert body =~ "Conflicting files: `lib/a.ex`, `docs/b.md`."
    refute_received {:auto_merge, _}

    assert :ok = LandingWatch.poll(Keyword.put(opts, :ticket_state_fun, fn "17", _ -> {:ok, %{state: "rework", paused?: false}} end))
    refute_received {:update_branch, _, _}
  end

  test "a queued conflicting PR is never updated; it is withdrawn and routed as before" do
    parent = self()

    assert :ok = LandingWatch.poll(cycle_opts(parent, %{conflicting() | merge_queue_entry: %{"id" => "MQE_1"}}, {:ok, %{}}))
    refute_received {:update_branch, _, _}
    assert_received {:withdraw, 17}
    assert_received {:transition, "17", "rework", _}
  end

  test "a draft, an unapproved head, or a request-changes head is never updated" do
    parent = self()
    opts = cycle_opts(parent, conflicting(), {:ok, %{}})
    changes_requested = %{conflicting() | review_decision: "CHANGES_REQUESTED", raw: %{conflicting().raw | "reviewDecision" => "CHANGES_REQUESTED"}}
    stale_approval = %{conflicting() | raw: %{conflicting().raw | "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "older-sha"}}]}}}

    for observation <- [%{conflicting() | draft?: true}, changes_requested, stale_approval] do
      assert :skip = ConflictUpdate.attempt(observation, opts)
    end

    refute_received {:update_branch, _, _}
  end

  test "the shared automatic-requeue cap holds the update without routing rework" do
    parent = self()
    opts = cycle_opts(parent, conflicting(), {:ok, %{}}) |> Keyword.put(:now_ms, 1_000_000)
    for _ <- 1..4, do: assert(:ok = Journal.reserve_merge_group_requeue(1_000_000, opts))

    assert :ok = LandingWatch.poll(opts)
    refute_received {:update_branch, _, _}
    refute_received {:transition, _, _, _}

    assert :ok = LandingWatch.poll(Keyword.put(opts, :now_ms, 1_000_000 + 15 * 60_000))
    assert_received {:update_branch, 17, "head-sha"}
  end

  test "conflict_files lists the paths a local merge-tree finds in conflict" do
    root = tmp_dir()
    origin = Path.join(root, "origin")
    git = fn args -> {_, 0} = System.cmd("git", ["-C", origin, "-c", "user.name=t", "-c", "user.email=t@t" | args], stderr_to_stdout: true) end

    File.mkdir_p!(origin)
    git.(["init", "--quiet", "--initial-branch=main"])
    File.write!(Path.join(origin, "a.txt"), "base\n")
    File.write!(Path.join(origin, "clean.txt"), "base\n")
    git.(["add", "."])
    git.(["commit", "--quiet", "-m", "base"])
    git.(["checkout", "--quiet", "-b", "pr"])
    File.write!(Path.join(origin, "a.txt"), "pr\n")
    git.(["commit", "--quiet", "-am", "pr"])
    git.(["update-ref", "refs/pull/9/head", "pr"])
    git.(["checkout", "--quiet", "main"])
    File.write!(Path.join(origin, "a.txt"), "main\n")
    File.write!(Path.join(origin, "clean.txt"), "main\n")
    git.(["commit", "--quiet", "-am", "main"])

    opts = [conflict_remote: origin, conflict_cache: Path.join(root, "cache.git")]
    assert {:ok, ["a.txt"]} = ConflictUpdate.conflict_files(%{number: 9, base: "main"}, opts)
  end

  defp cycle_opts(parent, observation, update_result) do
    path = Path.join(tmp_dir(), "journal.json")
    :ok = Journal.record_pause_writer("17", :approval_pause, journal_path: path)

    [
      observe_fun: fn _ -> {:ok, [observation]} end,
      journal_prune_fun: fn _, _ -> :ok end,
      queue_reconcile_fun: fn _, _ -> :ok end,
      approved_fun: fn _, _ -> {:ok, true} end,
      required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
      ci_status_fun: fn _, _ -> {:ok, %{check_runs: [@green], commit_status: %{"state" => "success", "statuses" => []}}} end,
      revalidate_fun: fn _, _, _ -> :ok end,
      attribution_fun: fn _ -> {:ok, :clean} end,
      enqueue_fun: fn pr ->
        send(parent, {:enqueued, pr.head})
        {:ok, "entry-1"}
      end,
      update_branch_fun: fn number, head, _ ->
        send(parent, {:update_branch, number, head})
        update_result
      end,
      auto_merge_fun: fn id, _ ->
        send(parent, {:auto_merge, id})
        :ok
      end,
      conflict_files_fun: fn %{number: 17}, _ -> {:ok, ["lib/a.ex", "docs/b.md"]} end,
      ticket_state_fun: fn "17", _ -> {:ok, %{state: "human-review", paused?: true}} end,
      withdraw_fun: fn number ->
        send(parent, {:withdraw, number})
        {:ok, [:dequeued]}
      end,
      transition_fun: fn id, target, options ->
        send(parent, {:transition, id, target, options})
        :ok
      end,
      comment_fun: fn id, body ->
        send(parent, {:comment, id, body})
        :ok
      end,
      write_marker_fun: fn _id, :remove, _label, _writer_opts -> :ok end,
      pause_label: "agent:paused",
      journal_path: path,
      alert_emitter: fn _, _ -> :ok end
    ]
  end

  defp conflicting do
    %{
      number: 17,
      node_id: "PR_node",
      head: "head-sha",
      base: "main",
      base_oid: "main-1",
      draft?: false,
      review_decision: "APPROVED",
      mergeable: "CONFLICTING",
      merge_state_status: "DIRTY",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/17-work"}},
      raw: %{"reviewDecision" => "APPROVED", "headRefOid" => "head-sha", "isDraft" => false, "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-sha"}}]}}
    }
  end

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "landing-watch-conflict-update-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    path
  end
end
