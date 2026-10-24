defmodule Aiur.LandingWatch.MergeGroupFailureRepeatTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.{Journal, MergeGroupFailureProcessor}

  test "a second failure of the same spec routes the PR to rework" do
    parent = self()
    path = journal_path()

    assert :ok = process_failure(101, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent)
    assert_received {:enqueue, 17}
    refute_received {:rework, 17}

    assert :ok = process_failure(102, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent)
    assert_received {:rework, 17}
    refute_received {:enqueue, 17}

    assert {:ok, 1} =
             Journal.merge_group_failure_attempts(
               17,
               "head-17",
               "test reports parity (Aiur.ParityTest) :: src/test/aiur/parity_test.exs",
               journal_path: path
             )

    Aiur.TestCleanup.rm_rf!(path)
  end

  test "a different failing spec gets its own re-enqueue" do
    parent = self()
    path = journal_path()

    assert :ok = process_failure(201, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent)
    assert_received {:enqueue, 17}
    assert :ok = process_failure(202, [{"reports other", "test/aiur/other_test.exs"}], path, parent)

    assert_received {:enqueue, 17}
    refute_received {:rework, 17}

    assert {:ok, 1} =
             Journal.merge_group_failure_attempts(
               17,
               "head-17",
               "test reports parity (Aiur.ParityTest) :: src/test/aiur/parity_test.exs",
               journal_path: path
             )

    Aiur.TestCleanup.rm_rf!(path)
  end

  test "different tests in one file get independent repeat counters" do
    parent = self()
    path = journal_path()

    assert :ok = process_failure(221, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent)
    assert_received {:enqueue, 17}

    assert :ok = process_failure(222, [{"reports another parity", "test/aiur/parity_test.exs"}], path, parent)

    assert_received {:enqueue, 17}
    refute_received {:rework, 17}
    Aiur.TestCleanup.rm_rf!(path)
  end

  test "a repeated spec among multiple failures routes the PR to rework" do
    parent = self()
    path = journal_path()

    assert :ok = process_failure(251, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent)
    assert_received {:enqueue, 17}

    assert :ok =
             process_failure(
               252,
               [
                 {"reports parity", "test/aiur/parity_test.exs"},
                 {"reports other", "test/aiur/other_test.exs"}
               ],
               path,
               parent
             )

    assert_received {:rework, 17}
    refute_received {:enqueue, 17}
    Aiur.TestCleanup.rm_rf!(path)
  end

  test "a prior multi-spec failure is detected when only one spec repeats" do
    parent = self()
    path = journal_path()

    assert :ok =
             process_failure(
               261,
               [
                 {"reports parity", "test/aiur/parity_test.exs"},
                 {"reports other", "test/aiur/other_test.exs"}
               ],
               path,
               parent
             )

    assert_received {:enqueue, 17}
    assert :ok = process_failure(262, [{"reports other", "test/aiur/other_test.exs"}], path, parent)
    assert_received {:rework, 17}
    refute_received {:enqueue, 17}
    Aiur.TestCleanup.rm_rf!(path)
  end

  # Existing-behavior regression guard; it is not counted as new repeat-routing coverage.
  test "a quarantined first failure still re-enqueues" do
    parent = self()
    path = journal_path()

    assert :ok =
             process_failure(301, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent,
               quarantined_run_ids: [301],
               recent_main_failure_paths_fun: fn _, _ -> {:ok, []} end
             )

    assert_received {:enqueue, 17}
    refute_received {:rework, 17}

    assert {:ok, 0} =
             Journal.merge_group_failure_attempts(
               17,
               "head-17",
               "test reports parity (Aiur.ParityTest) :: src/test/aiur/parity_test.exs",
               journal_path: path
             )

    Aiur.TestCleanup.rm_rf!(path)
  end

  test "per-spec repeat counters survive pruning other PR heads" do
    path = journal_path()
    opts = [journal_path: path]
    identity = "test reports parity (Aiur.ParityTest) :: src/test/aiur/parity_test.exs"

    other_identity = "test reports other (Aiur.OtherTest) :: src/test/aiur/other_test.exs"

    assert {:ok, _} =
             Journal.record_merge_group_failure_attempts(
               [{17, "head-17", [identity]}, {18, "head-18", [other_identity]}],
               opts
             )

    assert :ok = Journal.retain_current_heads([%{number: 17, head: "head-17"}], opts)
    assert {:ok, 1} = Journal.merge_group_failure_attempts(17, "head-17", identity, opts)
    assert {:ok, 1} = Journal.merge_group_failure_attempts(18, "head-18", other_identity, opts)
    Aiur.TestCleanup.rm_rf!(path)
  end

  test "a cancelled merge-group run is ignored" do
    path = journal_path()
    run = failed_run(401, "cancelled")

    assert :ok =
             MergeGroupFailureProcessor.process_completed(
               [run],
               [observation()],
               "main",
               journal_path: path,
               jobs_fun: fn _, _ -> flunk("cancelled runs are not classified") end
             )

    refute File.exists?(path)
  end

  defp process_failure(run_id, tests, journal, parent, extra_opts \\ []) do
    run = failed_run(run_id, "failure")
    log = failure_log(tests)

    opts = [
      journal_path: journal,
      recent_main_failure_paths_fun: fn _, _ -> {:ok, Enum.map(tests, fn {_name, path} -> "src/" <> path end)} end,
      known_failure_patterns: [],
      changed_paths_fun: fn _, _ -> {:ok, []} end,
      changed_paths_by_pr: %{17 => []},
      jobs_fun: fn _, _ -> {:ok, [%{"id" => run_id + 1, "name" => "parity", "conclusion" => "failure"}]} end,
      job_log_fun: fn _, _ -> {:ok, log} end,
      repo_fun: fn -> {:ok, {"owner", "repo"}} end,
      enqueue_fun: fn node, _head, _ ->
        send(parent, {:enqueue, 17})
        {:ok, "entry-#{node}"}
      end,
      approved_fun: fn _, _ -> {:ok, true} end,
      revalidate_fun: fn _, _, _ -> :ok end,
      attribution_fun: fn _ -> {:ok, :clean} end,
      comment_fun: fn _, _, _ -> :ok end,
      rework_fun: fn pr, _, _ ->
        send(parent, {:rework, pr.number})
        :ok
      end
    ]

    MergeGroupFailureProcessor.process_completed([run], [observation()], "main", Keyword.merge(opts, extra_opts))
  end

  defp failure_log(tests) do
    tests
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {{name, path}, index} ->
      "  #{index}) test #{name} (Aiur.ParityTest)\n     #{path}:42"
    end)
  end

  defp failed_run(id, conclusion) do
    %{
      "id" => id,
      "event" => "merge_group",
      "status" => "completed",
      "conclusion" => conclusion,
      "head_branch" => "gh-readonly-queue/main/pr-17-a"
    }
  end

  defp observation do
    %{
      number: 17,
      base: "main",
      head: "head-17",
      node_id: "PR_17",
      draft?: false,
      review_decision: "APPROVED",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/17-work"}}
    }
  end

  defp journal_path, do: Path.join(System.tmp_dir!(), "merge-group-repeat-#{System.unique_integer([:positive])}.json")
end
