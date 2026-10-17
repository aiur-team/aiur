defmodule Aiur.LandingWatch.JournalTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.Journal

  test "rerun reservation enforces per-head limit and resets for a new head" do
    path = Path.join(System.tmp_dir!(), "landing-journal-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    opts = [journal_path: path]

    assert :ok = Journal.reserve_rerun(23, "head-a", 1_000_000, opts)
    assert {:error, :rerun_backoff} = Journal.reserve_rerun(23, "head-a", 1_059_999, opts)
    assert :ok = Journal.reserve_rerun(23, "head-a", 1_060_000, opts)
    assert {:error, :rerun_limit_reached} = Journal.reserve_rerun(23, "head-a", 1_359_999, opts)
    assert {:error, :rerun_limit_reached} = Journal.reserve_rerun(23, "head-a", 1_360_000, opts)
    assert :ok = Journal.reserve_rerun(23, "head-b", 1_060_000, opts)

    assert :ok = Journal.mark_landed(23, "head-b", "entry-b", opts)
    assert :ok = Journal.reserve_rerun(23, "head-b", 1_120_000, opts)
    assert {:error, :rerun_limit_reached} = Journal.reserve_rerun(23, "head-b", 1_420_000, opts)

    assert {:ok, %{"23:head-b" => %{"rerun_count" => 2, "landing" => "queued", "entry" => "entry-b"}}} = Journal.state(opts)
  end

  test "merge-group flake idempotency survives pruning unrelated PR heads" do
    path = Path.join(System.tmp_dir!(), "landing-flake-journal-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    opts = [journal_path: path]

    assert {:ok, :new} = Journal.claim_flake("ExampleTest :: flaky :: run 42", opts)
    assert :ok = Journal.retain_current_heads([%{number: 9, head: "head-9"}], opts)
    assert {:ok, :already_claimed} = Journal.claim_flake("ExampleTest :: flaky :: run 42", opts)
    assert {:ok, state} = Journal.state(opts)
    assert Map.has_key?(state, "flakes")
  end

  test "merge-group run claims dedupe completed runs and can be released after an error" do
    path = Path.join(System.tmp_dir!(), "landing-run-journal-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    opts = [journal_path: path]

    assert {:ok, :new} = Journal.claim_merge_group_run(42, opts)
    assert {:ok, :already_claimed} = Journal.claim_merge_group_run(42, opts)
    assert :ok = Journal.retain_current_heads([%{number: 9, head: "head-9"}], opts)
    assert {:ok, :already_claimed} = Journal.claim_merge_group_run(42, opts)
    assert :ok = Journal.release_merge_group_run(42, opts)
    assert {:ok, :new} = Journal.claim_merge_group_run(42, opts)
  end

  test "merge-group auto-requeues stop at three in a rolling fifteen-minute window" do
    path = Path.join(System.tmp_dir!(), "landing-merge-requeue-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    opts = [journal_path: path]

    assert :ok = Journal.reserve_merge_group_requeue(1_000_000, opts)
    assert :ok = Journal.reserve_merge_group_requeue(1_001_000, opts)
    assert :ok = Journal.reserve_merge_group_requeue(1_002_000, opts)
    assert {:error, :merge_group_requeue_limit_reached} = Journal.reserve_merge_group_requeue(1_003_000, opts)
    assert {:ok, %{"1970-01-01T00:00:00Z" => 3}} = Journal.merge_group_requeues_by_hour(opts)
    assert :ok = Journal.reserve_merge_group_requeue(1_900_000, opts)
  end

  test "merge-group requeue cap survives reloading the durable journal" do
    path = Path.join(System.tmp_dir!(), "landing-merge-requeue-reload-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    first_boot_opts = [journal_path: path]

    assert :ok = Journal.reserve_merge_group_requeue(1_000_000, first_boot_opts)
    assert :ok = Journal.reserve_merge_group_requeue(1_001_000, first_boot_opts)
    assert :ok = Journal.reserve_merge_group_requeue(1_002_000, first_boot_opts)

    second_boot_opts = [journal_path: path]

    assert {:ok, %{"merge_group_requeues" => [1_002_000, 1_001_000, 1_000_000]}} =
             Journal.state(second_boot_opts)

    assert {:error, :merge_group_requeue_limit_reached} = Journal.reserve_merge_group_requeue(1_003_000, second_boot_opts)
  end
end
