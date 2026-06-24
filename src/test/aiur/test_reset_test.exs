defmodule Aiur.TestResetTest do
  use ExUnit.Case, async: false

  alias Aiur.TestReset

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "aiur_test_reset_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    previous_agent_workspace = System.get_env("AIUR_AGENT_WORKSPACE")
    previous_agent_ir_sandbox = System.get_env("AIUR_AGENT_IR_SANDBOX")
    System.delete_env("AIUR_AGENT_WORKSPACE")
    System.delete_env("AIUR_AGENT_IR_SANDBOX")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      restore_system_env("AIUR_AGENT_WORKSPACE", previous_agent_workspace)
      restore_system_env("AIUR_AGENT_IR_SANDBOX", previous_agent_ir_sandbox)
    end)

    %{tmp_dir: tmp_dir}
  end

  defp with_env(overrides, fun) do
    previous = Map.new(overrides, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(overrides, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp write_reset_fixture!(tmp, tickets \\ [101, 102, 103]) do
    File.mkdir_p!(Path.join(tmp, "src/lib/aiur/sandbox"))

    {_, 0} = System.cmd("git", ["init"], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: tmp)

    for name <- [
          "event_flow_demo.ex",
          "event_flow_unrelated_1.ex",
          "event_flow_unrelated_2.ex",
          "event_flow_unrelated_3.ex"
        ] do
      File.write!(Path.join([tmp, "src/lib/aiur/sandbox", name]), "defmodule X do\nend\n")
    end

    File.write!(Path.join(tmp, ".aiur-test-tickets.json"), Jason.encode!(%{"tickets" => tickets}))

    {_, 0} = System.cmd("git", ["add", "."], cd: tmp)
    {_, 0} = System.cmd("git", ["commit", "-m", "baseline"], cd: tmp)
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

    test "ABORT: direct reset from agent workspace env marker remains blocked", %{tmp_dir: tmp_dir} do
      write_reset_fixture!(tmp_dir)

      with_env(
        [
          {"AIUR_AGENT_WORKSPACE", "/tmp/aiur-workspaces/repo/334"},
          {"AIUR_AGENT_IR_SANDBOX", nil}
        ],
        fn ->
          assert {:error, :agent_workspace_blocked} =
                   TestReset.run(%{repo_root: tmp_dir, confirm: false, allow_remote: true})
        end
      )
    end

    test "agent IR sandbox marker allows reset guard to proceed", %{tmp_dir: tmp_dir} do
      write_reset_fixture!(tmp_dir)

      with_env(
        [
          {"AIUR_AGENT_WORKSPACE", "/tmp/aiur-workspaces/repo/334"},
          {"AIUR_AGENT_IR_SANDBOX", "1"}
        ],
        fn ->
          assert :ok = TestReset.run(%{repo_root: tmp_dir, confirm: false, allow_remote: true})
        end
      )
    end

    test "ABORT: direct reset from aiur-workspaces repo path remains blocked" do
      tmp =
        Path.join([
          System.tmp_dir!(),
          "aiur-workspaces",
          "repo",
          "direct-reset-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(tmp)
      write_reset_fixture!(tmp)

      try do
        with_env(
          [
            {"AIUR_AGENT_WORKSPACE", nil},
            {"AIUR_AGENT_IR_SANDBOX", nil}
          ],
          fn ->
            assert {:error, :agent_workspace_blocked} =
                     TestReset.run(%{repo_root: tmp, confirm: false, allow_remote: true})
          end
        )
      after
        File.rm_rf!(Path.join(System.tmp_dir!(), "aiur-workspaces"))
      end
    end
  end

  describe "dry-run output" do
    test "dry-run with valid tickets returns :ok, no side effects" do
      # Synthesize a fully-baked repo: git-init, commit sandbox baselines,
      # write tickets file, then run dry-run.
      tmp = Path.join(System.tmp_dir!(), "aiur_dry_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "src/lib/aiur/sandbox"))

      {_, 0} = System.cmd("git", ["init"], cd: tmp, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: tmp)

      for name <- [
            "event_flow_demo.ex",
            "event_flow_unrelated_1.ex",
            "event_flow_unrelated_2.ex",
            "event_flow_unrelated_3.ex"
          ] do
        File.write!(Path.join([tmp, "src/lib/aiur/sandbox", name]), "defmodule X do\nend\n")
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

    test "single dry-run returns :ok and resets only the first ticket, no side effects" do
      tmp = Path.join(System.tmp_dir!(), "aiur_single_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "src/lib/aiur/sandbox"))

      {_, 0} = System.cmd("git", ["init"], cd: tmp, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: tmp)
      {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: tmp)

      for name <- [
            "event_flow_demo.ex",
            "event_flow_unrelated_1.ex",
            "event_flow_unrelated_2.ex",
            "event_flow_unrelated_3.ex"
          ] do
        File.write!(Path.join([tmp, "src/lib/aiur/sandbox", name]), "defmodule X do\nend\n")
      end

      File.write!(Path.join(tmp, ".aiur-test-tickets.json"), ~s({"tickets": [99, 100, 101]}))

      {_, 0} = System.cmd("git", ["add", "."], cd: tmp)
      {_, 0} = System.cmd("git", ["commit", "-m", "baseline"], cd: tmp)

      try do
        output =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            assert :ok =
                     TestReset.run(%{
                       repo_root: tmp,
                       confirm: false,
                       single: true,
                       allow_remote: true
                     })
          end)

        assert output =~ "--test DRY-RUN"
        # Single mode narrows the blocker chain to the first ticket only.
        assert output =~ "- 99"
        refute output =~ "- 100"
        refute output =~ "- 101"
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

  # Regression: a single `gh issue edit` to set agent:todo is flaky — GitHub
  # GraphQL intermittently 401s during a reset. When it failed, the ticket was
  # left unlabeled and the orchestrator never dispatched it, stranding the whole
  # 3-ticket chain (e.g. #101 pauses forever waiting on the never-dispatched
  # #100 → ~90 min timeout). apply_label_reset/5 retries the pair, then reports
  # failure so the caller can refuse to launch a doomed run.
  describe "apply_label_reset/5" do
    test "succeeds on the first attempt when both calls exit 0" do
      counter = :counters.new(1, [])

      runner = fn _argv ->
        :counters.add(counter, 1, 1)
        {"", 0}
      end

      assert :ok = TestReset.apply_label_reset(["remove"], ["add"], runner, 3, 0)
      # one remove + one add, no retries
      assert :counters.get(counter, 1) == 2
    end

    test "retries on a transient failure and then succeeds" do
      agent = start_supervised!({Agent, fn -> 0 end})

      # Fail the very first gh call (a 401 on the remove step), then succeed.
      runner = fn _argv ->
        n = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
        if n == 0, do: {"HTTP 401", 1}, else: {"", 0}
      end

      assert :ok = TestReset.apply_label_reset(["remove"], ["add"], runner, 3, 0)
    end

    test "returns {:error, output} after exhausting all attempts" do
      runner = fn _argv -> {"HTTP 401: Requires authentication\n", 1} end

      assert {:error, "HTTP 401: Requires authentication"} =
               TestReset.apply_label_reset(["remove"], ["add"], runner, 3, 0)
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
