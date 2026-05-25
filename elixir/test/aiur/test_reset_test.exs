defmodule Aiur.TestResetTest do
  use ExUnit.Case, async: false

  alias Aiur.TestReset

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "aiur_test_reset_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  describe "guards" do
    test "ABORT: tickets file missing", %{tmp_dir: tmp_dir} do
      assert {:error, :tickets_file_missing} =
               TestReset.run(%{repo_root: tmp_dir, confirm: false})
    end

    test "ABORT: tickets file with empty tickets list", %{tmp_dir: tmp_dir} do
      File.write!(
        Path.join(tmp_dir, ".aiur-test-tickets.json"),
        ~s({"tickets": [], "expected_remote": "x"})
      )

      assert {:error, :no_tickets_pinned} =
               TestReset.run(%{repo_root: tmp_dir, confirm: false})
    end

    test "ABORT: non-integer ticket ids", %{tmp_dir: tmp_dir} do
      File.write!(
        Path.join(tmp_dir, ".aiur-test-tickets.json"),
        ~s({"tickets": ["../etc/passwd"], "expected_remote": "x"})
      )

      assert {:error, {:invalid_ticket_ids, _}} =
               TestReset.run(%{repo_root: tmp_dir, confirm: false})
    end

    test "ABORT: dirty working tree without --force" do
      # Use a temp git repo with uncommitted changes
      tmp = Path.join(System.tmp_dir!(), "aiur_test_repo_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      {_, 0} = System.cmd("git", ["init"], cd: tmp, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: tmp)
      File.write!(Path.join(tmp, "README.md"), "stub\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: tmp)
      {_, 0} = System.cmd("git", ["commit", "-m", "init"], cd: tmp)

      # Make working tree dirty
      File.write!(Path.join(tmp, "README.md"), "changed\n")

      File.write!(
        Path.join(tmp, ".aiur-test-tickets.json"),
        ~s({"tickets": [101]})
      )

      original_cwd = File.cwd!()
      File.cd!(tmp)

      try do
        assert {:error, :dirty_working_tree} = TestReset.run(%{repo_root: tmp, confirm: false})
      after
        File.cd!(original_cwd)
        File.rm_rf!(tmp)
      end
    end
  end

  describe "dry-run output" do
    test "dry-run with valid tickets returns :ok, no side effects" do
      # Synthesize a fully-baked repo: git-init, commit sandbox baselines,
      # write tickets file, then run dry-run.
      tmp = Path.join(System.tmp_dir!(), "aiur_dry_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "elixir/lib/aiur/sandbox"))

      {_, 0} = System.cmd("git", ["init"], cd: tmp, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: tmp)

      for name <- [
            "event_flow_demo.ex",
            "event_flow_unrelated_1.ex",
            "event_flow_unrelated_2.ex",
            "event_flow_unrelated_3.ex"
          ] do
        File.write!(Path.join([tmp, "elixir/lib/aiur/sandbox", name]), "defmodule X do\nend\n")
      end

      File.write!(
        Path.join(tmp, ".aiur-test-tickets.json"),
        ~s({"tickets": [101, 102, 103]})
      )

      {_, 0} = System.cmd("git", ["add", "."], cd: tmp)
      {_, 0} = System.cmd("git", ["commit", "-m", "baseline"], cd: tmp)

      try do
        assert :ok =
                 TestReset.run(%{
                   repo_root: tmp,
                   confirm: false,
                   allow_remote: true
                 })
      after
        File.rm_rf!(tmp)
      end
    end
  end
end
