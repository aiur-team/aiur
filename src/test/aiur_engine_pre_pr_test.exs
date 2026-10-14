defmodule AiurEnginePrePrTest do
  use ExUnit.Case, async: false

  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  test "conflicting origin main reports the file, aborts, and leaves the checkout clean" do
    fixture = fixture("conflict")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])
    File.write!(Path.join(repo, "collision.txt"), "feature\n")
    git!(repo, ["add", "collision.txt"])
    git!(repo, ["commit", "-m", "feature"])
    git!(repo, ["switch", "main"])
    File.write!(Path.join(repo, "collision.txt"), "main\n")
    git!(repo, ["commit", "-am", "main"])
    git!(repo, ["switch", "feature"])

    {output, status} = run_pre_pr(fixture, repo)

    assert status == 1
    assert output =~ "FAIL merge conflict: collision.txt"
    assert output =~ "Result: FAIL"
    assert length(Regex.scan(~r/--- aiur pre-pr result/, output)) == 1
    assert String.ends_with?(output, "--- end aiur pre-pr result ---\n")
    assert git_output!(repo, ["status", "--porcelain"]) == ""
    refute File.exists?(Path.join(fixture, "home/.aiur"))
    refute Enum.any?(File.ls!(fixture), &String.starts_with?(&1, "aiur-pre-pr."))
  end

  test "full-suite fallback is reported and matching reader tests run" do
    fixture = fixture("gate")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])
    File.mkdir_p!(Path.join(repo, "src/lib"))
    File.mkdir_p!(Path.join(repo, "src/test"))
    File.write!(Path.join(repo, "src/lib/changed.ex"), "defmodule Changed do end\n")

    File.write!(
      Path.join(repo, "src/test/changed_reader_test.exs"),
      "assert File.read!(\"src/lib/changed.ex\")\n"
    )

    File.write!(Path.join(repo, "src/test/changed_mention_test.exs"), "# src/lib/changed.ex\n")

    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "change source"])

    {output, status} = run_pre_pr(fixture, repo)

    assert status == 1
    assert output =~ "FAIL mix format --check-formatted"
    assert output =~ "NOTE full suite recommended (fixture requires full suite); runs in merge queue"
    assert output =~ "PASS reader tests"
    assert File.read!(Path.join(fixture, "reader-tests")) =~ "changed_reader_test.exs"
    refute File.read!(Path.join(fixture, "reader-tests")) =~ "changed_mention_test.exs"
    refute File.exists?(Path.join(fixture, "make-ci-ran"))
    assert File.read!(Path.join(fixture, "test-env")) == "clean\nclean\n"
    temp_dirs = fixture |> then(&Path.join(&1, "test-tmpdirs")) |> File.read!() |> String.split("\n", trim: true)
    assert length(temp_dirs) == 2
    assert Enum.all?(temp_dirs, &String.starts_with?(&1, Path.join(fixture, "aiur-pre-pr.")))
    assert output =~ "Result: FAIL"
    assert length(Regex.scan(~r/--- aiur pre-pr result/, output)) == 1
    assert :binary.match(output, "--- end aiur pre-pr result ---") < :binary.match(output, "format failure")
    refute File.exists?(Path.join(fixture, "home/.aiur"))
    refute Enum.any?(File.ls!(fixture), &String.starts_with?(&1, "aiur-pre-pr."))
  end

  test "reader selection matches a basename in a Path.join call" do
    fixture = fixture("basename-reader")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])
    skill = Path.join(repo, ".claude/skills/aiur-agent")
    File.mkdir_p!(skill)
    File.write!(Path.join(skill, "dev-loop.md"), "worker instruction\n")
    File.mkdir_p!(Path.join(repo, "src/test"))
    File.write!(Path.join(repo, "src/test/dev_loop_reader_test.exs"), "File.read!(Path.join(skill, \"dev-loop.md\"))\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "edit skill doc"])

    {output, _status} = run_pre_pr(fixture, repo)

    assert output =~ "PASS reader tests"
    assert File.read!(Path.join(fixture, "test-command")) =~ "dev_loop_reader_test.exs"
  end

  test "selector command failure is reported as a failure" do
    fixture = fixture("selector-failure")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])

    {output, status} = run_pre_pr(fixture, repo, selector_mode: "failure")

    assert status == 1
    assert output =~ "FAIL affected tests selection"
    assert output =~ "Result: FAIL"
    refute output =~ "PASS affected tests"
  end

  test "unknown selector status is reported as a failure" do
    fixture = fixture("selector-unknown")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])

    {output, status} = run_pre_pr(fixture, repo, selector_mode: "unknown")

    assert status == 1
    assert output =~ "FAIL affected tests selection (invalid selector response)"
    refute output =~ "PASS affected tests"
  end

  test "scoped selector runs its selected test files" do
    fixture = fixture("scoped-tests")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])
    File.mkdir_p!(Path.join(repo, "src/test"))
    File.write!(Path.join(repo, "src/test/scoped_test.exs"), "assert true\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "add scoped test"])

    {output, status} = run_pre_pr(fixture, repo, selector_mode: "scoped")

    assert status == 1
    assert output =~ "PASS affected tests"
    assert File.read!(Path.join(fixture, "test-command")) =~ "test/scoped_test.exs"
  end

  test "reader failures identify test files the branch did not edit" do
    fixture = fixture("unedited-reader")
    repo = Path.join(fixture, "repo")
    File.mkdir_p!(Path.join(repo, "src/lib"))
    File.mkdir_p!(Path.join(repo, "src/test"))
    File.write!(Path.join(repo, "src/lib/changed.ex"), "base\n")
    File.write!(Path.join(repo, "src/test/unmodified_reader_test.exs"), "File.read!(\"src/lib/changed.ex\")\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "base reader fixture"])
    git!(repo, ["switch", "-c", "feature"])
    File.write!(Path.join(repo, "src/lib/changed.ex"), "branch\n")
    git!(repo, ["commit", "-am", "edit source"])

    {output, status} = run_pre_pr(fixture, repo, reader_mode: "failure")

    assert status == 1
    assert output =~ "FAIL reader tests"
    assert output =~ "NOTE failing test files not edited by this branch: src/test/unmodified_reader_test.exs"
  end

  test "missing jq and rg fail closed" do
    for missing <- ["jq", "rg"] do
      fixture = fixture("missing-#{missing}")
      repo = Path.join(fixture, "repo")
      git!(repo, ["switch", "-c", "feature"])

      {output, status} = run_pre_pr(fixture, repo, missing_tool: missing)

      assert status == 1
      assert output =~ "FAIL required command: #{missing}"
      refute output =~ "PASS"
    end
  end

  test "successful full-suite fallback says which checks were not run" do
    fixture = fixture("not-run")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])

    {output, status} = run_pre_pr(fixture, repo, gate_mode: "pass")

    assert status == 0
    assert output =~ "Result: PASS (full suite not run)"
    assert output =~ "Not run: Credo and specs (make lint), dialyzer, full suite"
  end

  defp fixture(name) do
    root = Aiur.TestSupport.tmp_root!("pre-pr-#{name}")
    repo = Path.join(root, "repo")
    bin = Path.join(root, "bin")
    File.mkdir_p!(repo)
    File.mkdir_p!(bin)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.email", "pre-pr@example.invalid"])
    git!(repo, ["config", "user.name", "pre-pr test"])
    git!(repo, ["remote", "add", "origin", "."])
    File.mkdir_p!(Path.join(repo, "src"))
    File.mkdir_p!(Path.join(repo, "scripts"))
    File.write!(Path.join(repo, "src/mix.exs"), "")

    for script <- ["check-pr-structure.py", "check-file-size.py", "check-config-docs.py", "check-hot-list-format.py"] do
      File.write!(Path.join(repo, "scripts/#{script}"), "")
    end

    File.write!(Path.join(repo, "collision.txt"), "base\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "base"])
    write_fake_tools(bin, root)
    root
  end

  defp write_fake_tools(bin, root) do
    mise = """
    #!/usr/bin/env bash
    case "$*" in
      *"mix test"*)
        if [ -n "${AIUR_AGENT_WORKSPACE+x}${AIUR_INSTANCE_KEY+x}${AIUR_PROJECT_ROOT+x}" ]; then echo leaked > "#{root}/test-env"; exit 79; fi
        echo clean >> "#{root}/test-env"
        echo "$TMPDIR" >> "#{root}/test-tmpdirs"
        echo "$*" > "#{root}/test-command"
        if [ "${PRE_PR_READER_MODE:-}" = failure ] && [[ "$*" == *unmodified_reader_test.exs* ]]; then echo '     test/unmodified_reader_test.exs:28'; exit 2; fi
        case "$*" in *changed_reader_test.exs*) echo "$*" > "#{root}/reader-tests" ;; esac
        ;;
    esac
    case "$*" in
      *"mix aiur.affected_tests"*)
        case "${PRE_PR_SELECTOR_MODE:-full}" in
          failure) exit 42 ;;
          unknown) echo '{"status":"unexpected"}' ;;
          scoped) echo '{"status":"scoped","tests":["src/test/scoped_test.exs"]}' ;;
          *) echo '{"status":"full","reason":"fixture requires full suite"}' ;;
        esac
        ;;
      *"make ci"*) echo yes > "#{root}/make-ci-ran"; exit 88 ;;
      *"mix format"*)
        if [ "${PRE_PR_GATE_MODE:-fail}" = pass ]; then exit 0; fi
        echo 'format failure'; exit 13
        ;;
      *) exit 0 ;;
    esac
    """

    gh = "#!/usr/bin/env bash\necho 'no PR' >&2\nexit 1\n"

    for {name, contents} <- [{"mise", mise}, {"gh", gh}] do
      path = Path.join(bin, name)
      File.write!(path, contents)
      File.chmod!(path, 0o755)
    end
  end

  defp run_pre_pr(fixture, repo, opts \\ []) do
    env = [
      {"AIUR_ENGINE", @engine},
      {"AIUR_AGENT_WORKSPACE", repo},
      {"AIUR_BASE_BRANCH", "main"},
      {"HOME", Path.join(fixture, "home")},
      {"TMPDIR", fixture},
      {"PATH", Path.join(fixture, "bin") <> ":" <> System.get_env("PATH")},
      {"PRE_PR_SELECTOR_MODE", Keyword.get(opts, :selector_mode, "full")},
      {"PRE_PR_GATE_MODE", Keyword.get(opts, :gate_mode, "fail")},
      {"PRE_PR_READER_MODE", Keyword.get(opts, :reader_mode, "pass")},
      {"PRE_PR_MISSING_TOOL", Keyword.get(opts, :missing_tool, "")}
    ]

    command = "command() { if [ \"$1\" = -v ] && [ \"$2\" = \"${PRE_PR_MISSING_TOOL:-}\" ]; then return 1; fi; builtin command \"$@\"; }; source \"$AIUR_ENGINE\"; aiur_engine_main pre-pr"

    System.cmd("bash", ["-c", command],
      cd: repo,
      env: env,
      stderr_to_stdout: true
    )
  end

  defp git!(repo, args) do
    {output, status} =
      System.cmd("git", args,
        cd: repo,
        env: [{"AIUR_AGENT_WORKSPACE", repo}],
        stderr_to_stdout: true
      )

    if status != 0, do: flunk("git #{Enum.join(args, " ")} failed: #{output}")
    output
  end

  defp git_output!(repo, args), do: repo |> git!(args) |> String.trim()
end
