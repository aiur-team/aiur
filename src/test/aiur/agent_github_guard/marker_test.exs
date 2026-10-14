defmodule Aiur.AgentGitHubGuard.MarkerTest do
  use Aiur.AgentGitHubGuardCase, async: true

  # #2501 — single-account provenance marker.
  #
  # The agent composes its comment body inside its own process and posts it with
  # `gh`, so the wrapper is the only place the daemon can attach provenance to
  # it. Without the marker, a single-account install cannot tell that comment
  # from one the operator typed under the same login.
  describe "single-account comment marker" do
    @marker "<!-- aiur:agent-authored -->"

    defp forwarded_args(context, args, extra_env) do
      recorded = Path.join(context.workspace, "forwarded-args-#{System.unique_integer([:positive])}")
      {_output, 0} = run_guard(context, args, [{:FAKE_GH_ARGS, recorded}] ++ extra_env)
      File.read!(recorded)
    end

    test "appends the marker to an agent's issue comment body", context do
      forwarded =
        forwarded_args(context, ["issue", "comment", "1670", "--body", "Rework applied."], AIUR_AGENT_COMMENT_MARKER: @marker)

      assert forwarded =~ "Rework applied."
      assert forwarded =~ @marker
    end

    test "covers pr comment and pr review, and the --body= and -b spellings", context do
      for args <- [
            ["pr", "comment", "1670", "--body", "Pushed the fix."],
            ["pr", "comment", "1670", "--body=Pushed the fix."],
            ["pr", "review", "1670", "--comment", "-b", "Pushed the fix."]
          ] do
        forwarded = forwarded_args(context, args, AIUR_AGENT_COMMENT_MARKER: @marker)

        assert forwarded =~ "Pushed the fix.", "no body forwarded for #{inspect(args)}"
        assert forwarded =~ @marker, "no marker appended for #{inspect(args)}"
      end
    end

    test "leaves the rest of argv, and its order, alone", context do
      forwarded =
        forwarded_args(
          context,
          ["pr", "review", "1670", "-R", "owner/aiur", "--comment", "--body", "fine"],
          AIUR_AGENT_COMMENT_MARKER: @marker
        )

      assert forwarded =~ "pr review 1670 -R owner/aiur --comment --body fine"
    end

    test "does not stamp twice when the body already carries the marker", context do
      forwarded =
        forwarded_args(context, ["issue", "comment", "1670", "--body", "Done.\n\n" <> @marker], AIUR_AGENT_COMMENT_MARKER: @marker)

      assert forwarded |> String.split(@marker) |> length() == 2
    end

    test "separate-account mode leaves the body untouched", context do
      # The variable is exported only on a single-account install, so an
      # unset one must change nothing at all.
      forwarded = forwarded_args(context, ["issue", "comment", "1670", "--body", "Rework applied."], [])

      assert forwarded =~ "Rework applied."
      refute forwarded =~ @marker
      refute forwarded =~ "aiur:agent"
    end

    # The bytes `gh` actually received for a `--body-file` call. The guard
    # deletes its marked copy on exit, so this is captured inside the call.
    defp sent_body(context, args, extra_env) do
      sink = Path.join(context.workspace, "sent-body-#{System.unique_integer([:positive])}")
      {_output, 0} = run_guard(context, args, [{:FAKE_GH_BODY_SINK, sink}] ++ extra_env)
      File.read!(sink)
    end

    test "stamps a --body-file, which is the spelling the skills mandate", context do
      # `Aiur.GitHubBodyFilePolicyTest` forbids inline bodies, so `--body-file`
      # is what an agent actually uses. Leaving it unstamped would mean the
      # common agent comment is never marked and every agent wakes on its own
      # reply — the requirement's other half.
      body_file = Path.join(context.workspace, "reply.md")
      File.write!(body_file, "Rework applied.\n")

      sent =
        sent_body(context, ["issue", "comment", "1670", "--body-file", body_file], AIUR_AGENT_COMMENT_MARKER: @marker)

      assert sent =~ "Rework applied."
      assert sent =~ @marker

      # The agent's own file is copied, never edited: it may be read again.
      assert File.read!(body_file) == "Rework applied.\n"
    end

    test "covers the --body-file= and -F spellings", context do
      for {build_args, label} <- [
            {fn f -> ["pr", "comment", "1670", "--body-file=" <> f] end, "--body-file="},
            {fn f -> ["issue", "comment", "1670", "-F", f] end, "-F"}
          ] do
        body_file = Path.join(context.workspace, "reply-#{System.unique_integer([:positive])}.md")
        File.write!(body_file, "Pushed the fix.\n")

        sent = sent_body(context, build_args.(body_file), AIUR_AGENT_COMMENT_MARKER: @marker)

        assert sent =~ @marker, "no marker for #{label}"
        assert sent =~ "Pushed the fix.", "body lost for #{label}"
      end
    end

    test "an already-marked body file is not stamped twice", context do
      body_file = Path.join(context.workspace, "marked.md")
      File.write!(body_file, "Done.\n\n" <> @marker <> "\n")

      sent =
        sent_body(context, ["issue", "comment", "1670", "--body-file", body_file], AIUR_AGENT_COMMENT_MARKER: @marker)

      assert sent |> String.split(@marker) |> length() == 2
    end

    test "separate-account mode leaves a body file alone", context do
      body_file = Path.join(context.workspace, "plain.md")
      File.write!(body_file, "Rework applied.\n")

      sent = sent_body(context, ["issue", "comment", "1670", "--body-file", body_file], [])

      assert sent == "Rework applied.\n"
      assert File.read!(body_file) == "Rework applied.\n"
    end

    test "the marked copy does not outlive the call", context do
      body_file = Path.join(context.workspace, "temp-check.md")
      File.write!(body_file, "Rework applied.\n")

      forwarded =
        forwarded_args(context, ["issue", "comment", "1670", "--body-file", body_file], AIUR_AGENT_COMMENT_MARKER: @marker)

      sent_path = forwarded |> String.split() |> List.last()

      refute sent_path == body_file
      refute File.exists?(sent_path)
    end

    # The happy path deletes the marked copy on the way out, but the refusal
    # paths `exit` long before the budget traps are installed. Arming the
    # cleanup trap beside the marker block is what makes these exits clean;
    # with the trap left at its old position each refused call leaks one
    # `aiur-marked-body.*` into TMPDIR, one file per agent comment attempt.
    test "a refused call does not leak the marked copy into TMPDIR", context do
      body_file = Path.join(context.workspace, "refused.md")
      File.write!(body_file, "Please approve.\n")

      for {args, expected_status, expected_message} <- [
            {["pr", "review", "1670", "--approve", "--body-file", body_file], 77, "agents cannot approve or merge pull requests"},
            {["pr", "comment", "1670", "--body-file", body_file], 75, "GitHub shared budget unavailable"}
          ] do
        tmp = Path.join(context.workspace, "tmpdir-#{System.unique_integer([:positive])}")
        File.mkdir_p!(tmp)

        # `--body-file` alone does not reach the budget gate, so the second
        # case forces the budget-unavailable refusal with a root that holds no
        # usable broker.
        budget_env =
          if expected_status == 75 do
            [
              AIUR_GITHUB_BUDGET_ENABLED: "1",
              AIUR_GITHUB_BUDGET_ROOT: Path.join(tmp, "absent-budget")
            ]
          else
            []
          end

        {output, status} =
          run_guard(
            context,
            args,
            [TMPDIR: tmp, AIUR_AGENT_COMMENT_MARKER: @marker] ++ budget_env
          )

        assert status == expected_status, "unexpected status for #{inspect(args)}: #{output}"
        assert output =~ expected_message

        leaked =
          tmp
          |> File.ls!()
          |> Enum.filter(&String.starts_with?(&1, "aiur-marked-body."))

        assert leaked == [], "refusal #{expected_status} leaked #{inspect(leaked)} into TMPDIR"

        # The agent's own file is untouched by a refused call.
        assert File.read!(body_file) == "Please approve.\n"
      end
    end

    test "a command that is not a comment write is never rewritten", context do
      forwarded =
        forwarded_args(context, ["issue", "view", "1670", "--json", "body"], AIUR_AGENT_COMMENT_MARKER: @marker)

      refute forwarded =~ @marker
    end
  end

  test "allows a comment review whose body text looks like an approve flag", context do
    # `--approve` here is the VALUE of `--body`, not a flag. Refusing it would
    # make the guard unusable for the reviews an agent is supposed to leave.
    assert {"ok\n", 0} = run_guard(context, ["pr", "review", "7", "--comment", "--body", "--approve"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "review", "7", "--comment", "-b", "-a"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "review", "7", "-R", "owner/aiur", "--comment", "--body", "fine"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "review", "7", "-Rowner/aiur", "--comment", "--body", "fine"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "review", "7", "--comment", "--body", "ok", "--", "--approve"])

    assert File.read!(context.calls) =~ "pr review"
  end

  test "still allows the read-only commands and local config an agent needs", context do
    assert {"ok\n", 0} = run_guard(context, ["pr", "checks", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "diff", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["issue", "view", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/git/refs/heads/main"])
    assert {"ok\n", 0} = run_guard(context, ["alias", "list"])

    calls = File.read!(context.calls)
    assert calls =~ "pr checks"
    assert calls =~ "alias list"
  end

  test "leaves the Executor's own wrapper able to merge", context do
    # Only dispatched agents lose merge authority. The Executor runs the same
    # script from outside `.aiur-runtime/bin`, and must keep the gate it holds.
    executor_bin = Path.join(context.workspace, "executor-bin")
    File.mkdir_p!(executor_bin)
    executor_wrapper = Path.join(executor_bin, "gh")
    File.cp!(context.wrapper, executor_wrapper)
    File.chmod!(executor_wrapper, 0o755)

    # `System.cmd` merges the parent environment rather than replacing it, so
    # "remove the marker" is not enough when the test VM itself runs inside an
    # Aiur agent workspace (AIUR_AGENT_WORKSPACE is inherited back in). The
    # guard treats an empty AIUR_AGENT_WORKSPACE as absent
    # (`-z "${AIUR_AGENT_WORKSPACE:-}"`), so pin it to "" exactly as
    # `run_executor_guard` does.
    assert {"ok\n", 0} =
             System.cmd(
               executor_wrapper,
               ["pr", "merge", "1670"],
               env:
                 Enum.reject(guard_env(context), fn {name, _value} -> name == "AIUR_AGENT_WORKSPACE" end) ++
                   [{"AIUR_AGENT_WORKSPACE", ""}],
               stderr_to_stdout: true
             )
  end
end
