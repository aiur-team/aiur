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
end
