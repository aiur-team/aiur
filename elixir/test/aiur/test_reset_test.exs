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

    test "golden dry-run returns :ok and reads golden_ticket, no side effects" do
      tmp = Path.join(System.tmp_dir!(), "aiur_golden_#{System.unique_integer([:positive])}")
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

      File.write!(Path.join(tmp, ".aiur-test-tickets.json"), ~s({"tickets": [101]}))

      {_, 0} = System.cmd("git", ["add", "."], cd: tmp)
      {_, 0} = System.cmd("git", ["commit", "-m", "baseline"], cd: tmp)

      try do
        output =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            assert :ok =
                     TestReset.run(%{
                       repo_root: tmp,
                       confirm: false,
                       golden: true,
                       allow_remote: true
                     })
          end)

        assert output =~ "golden_ticket"
        assert output =~ "--test DRY-RUN"
      after
        File.rm_rf!(tmp)
      end
    end
  end

  # Regression: when reset_labels invoked `gh issue edit N --remove-label
  # "agent:todo,..." --add-label "agent:todo"` (same label in both),
  # the API resolved them such that the remove won, stripping the
  # label entirely. The orchestrator's next poll then saw the issue
  # as unlabeled and skipped dispatching it, producing the "agents
  # missing from the list / chat pane shows no agent text" symptom.
  # The fix is to issue remove and add as TWO separate gh invocations.
  describe "reset_labels_command_args/1" do
    test "returns two argv lists — strip-all then add — never combined" do
      args = TestReset.reset_labels_command_args(101)

      assert is_list(args), "expected a list of argv lists"
      assert length(args) == 2, "expected exactly two gh calls (remove, add) — got #{length(args)}"

      [remove_argv, add_argv] = args

      assert "--remove-label" in remove_argv,
             "first argv should be the strip-all step"

      refute "--add-label" in remove_argv,
             "the remove step must not also add — otherwise gh strips agent:todo"

      assert "--add-label" in add_argv,
             "second argv should be the add-agent:todo step"

      refute "--remove-label" in add_argv,
             "the add step must not also remove — gh's remove-then-add ordering is unsafe"

      # Both argvs must target issue 101.
      assert "101" in remove_argv
      assert "101" in add_argv

      # The add step must add specifically agent:todo.
      add_idx = Enum.find_index(add_argv, &(&1 == "--add-label"))
      assert Enum.at(add_argv, add_idx + 1) == "agent:todo"
    end

    test "stripped label set covers every known agent:* state" do
      [remove_argv, _add_argv] = TestReset.reset_labels_command_args(99)

      idx = Enum.find_index(remove_argv, &(&1 == "--remove-label"))
      label_csv = Enum.at(remove_argv, idx + 1)
      labels = String.split(label_csv, ",")

      # Every label the orchestrator can transition an issue into must
      # be cleared so reset always lands on a clean agent:todo.
      for required <- ~w(agent:todo agent:in-progress agent:human-review agent:rework agent:merging agent:done agent:error agent:cancelled agent:canceled) do
        assert required in labels, "remove set missing #{required}"
      end
    end
  end

  # Regression: `aiur --test` cleared labels, workspace, PR, and remote
  # branch — but did NOT touch the issue's comments. Agents store their
  # workpad as a comment whose body starts with `## Agent Workpad`, so
  # the next run's agent would read the stale workpad and reference
  # "prior workpad / previous attempt" in its first messages.
  # `workpad_comment?/1` is the predicate the reset uses to decide
  # which comments to delete.
  describe "workpad_comment?/1" do
    test "matches comments starting with the canonical workpad header" do
      assert TestReset.workpad_comment?(%{"body" => "## Agent Workpad\n\nplan goes here"})
    end

    test "matches even with leading whitespace before the header" do
      # Agents have occasionally been observed to prefix a stray newline
      # or a separator; tolerate that without re-classifying the comment.
      assert TestReset.workpad_comment?(%{"body" => "\n## Agent Workpad\n…"})
    end

    test "ignores comments that mention the workpad but don't lead with the header" do
      # A human review comment referencing a prior workpad is NOT a
      # workpad itself — must not be deleted.
      refute TestReset.workpad_comment?(%{
               "body" => "Re-reviewed the ## Agent Workpad above — looks good."
             })
    end

    test "ignores unrelated comments" do
      refute TestReset.workpad_comment?(%{"body" => "👍"})
      refute TestReset.workpad_comment?(%{"body" => "Manual review pass"})
    end

    test "ignores comments with missing/blank body" do
      refute TestReset.workpad_comment?(%{"body" => nil})
      refute TestReset.workpad_comment?(%{"body" => ""})
      refute TestReset.workpad_comment?(%{})
    end
  end
end
