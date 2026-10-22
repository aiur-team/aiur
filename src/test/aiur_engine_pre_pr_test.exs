defmodule AiurEnginePrePrTest do
  use ExUnit.Case, async: false

  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)
  @shim Path.expand("../../scripts/aiurdev", __DIR__)

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

  test "PR body refresh fixes stale head and writes plain base evidence" do
    fixture = fixture("body-refresh")
    repo = Path.join(fixture, "repo")
    sha = git_output!(repo, ["rev-parse", "HEAD"])
    pr_json = Path.join(fixture, "pr.json")

    body =
      "## Local tests\n\nPolicy: partial\nTested head: " <>
        String.duplicate("a", 40) <>
        "\nBase: `main` @ `" <> sha <> "`\nSelection: focused\n- `mix test` -> pass\n"

    # Each refresh rewrites pr.json, so every run starts again from this seed.
    File.write!(Path.join(fixture, "pr-seed.json"), Jason.encode!(%{"number" => 123, "body" => body}))

    File.write!(
      Path.join(fixture, "bin/gh"),
      """
      #!/usr/bin/env bash
      if [[ "$*" == *createdAt* ]]; then
        jq -n --arg sha "#{sha}" --arg body "$(cat "#{fixture}/edited-body.md")" --arg created_at "2026-01-01T00:00:00Z" '{created_at: $created_at, body: $body, head: {sha: $sha}}'
      elif [[ "$*" == *headRefOid* ]]; then
        poll=$(( $(cat "#{fixture}/polls" 2>/dev/null || echo 0) + 1 ))
        echo "$poll" > "#{fixture}/polls"
        (( poll > ${FAKE_MAX_POLLS:-99} )) && exit 3
        if (( poll >= ${FAKE_HEAD_FROM_POLL:-1} )); then echo '{"head":{"sha":"#{sha}"}}'; else echo '{"head":{"sha":"#{String.duplicate("b", 40)}"}}'; fi
      elif [[ "$*" == *pulls/123* ]]; then
        [[ "${FAIL_EDIT:-0}" == 1 ]] && exit 7
        while (($#)); do
          if [[ "$1" == --input ]]; then
            command python3 -c 'import json, pathlib, sys; pathlib.Path(sys.argv[2]).write_text(json.load(open(sys.argv[1]))["body"])' "$2" "#{fixture}/edited-body.md"
            exit $?
          fi
          shift
        done
        exit 8
      else
        exit 9
      fi
      """
    )

    File.chmod!(Path.join(fixture, "bin/gh"), 0o755)

    File.write!(
      Path.join(fixture, "refresh-wrapper.sh"),
      """
      source "#{@engine}"
      python3() {
        if [[ "$1" == scripts/check-pr-body.py ]]; then
          [[ "$2" == --pr-json ]] || return 1
          [[ $(jq -r '.head.sha' "$3") == $(git rev-parse HEAD) ]] || return 1
          local body
          body="$(jq -r '.body' "$3")"
          [[ "$body" == *"Tested head: $(git rev-parse HEAD)"* ]] || return 1
          [[ "$body" == *"Base: main @ #{sha}"* ]] || return 1
        else
          command python3 "$@"
        fi
      }
      refresh_pr_body_evidence "#{pr_json}" main "#{sha}"
      """
    )

    {output, status} = run_refresh(fixture, repo, [])

    assert status == 0, output
    refreshed = File.read!(Path.join(fixture, "edited-body.md"))
    assert refreshed =~ "Tested head: #{sha}\n"
    assert refreshed =~ "Base: main @ #{sha}\n"
    refute refreshed =~ "Tested head: `"
    refute refreshed =~ "Base: `"

    {output, failed_refresh} = run_refresh(fixture, repo, [{"FAIL_EDIT", "1"}])

    assert failed_refresh == 1
    assert File.read!(Path.join(fixture, "polls")) == "1\n", output

    # GitHub never reports the pushed head: fail after exactly the injected bound.
    {output, never} = run_refresh(fixture, repo, [{"FAKE_HEAD_FROM_POLL", "1000"}, {"FAKE_MAX_POLLS", "3"}, {"AIUR_PRE_PR_REFRESH_ATTEMPTS", "3"}])
    assert never == 1
    assert output =~ "did not report pushed head #{sha}"
    assert File.read!(Path.join(fixture, "polls")) == "3\n"

    # GitHub reports the pushed head on poll 3: pass.
    {output, late} = run_refresh(fixture, repo, [{"FAKE_HEAD_FROM_POLL", "3"}, {"FAKE_MAX_POLLS", "3"}, {"AIUR_PRE_PR_REFRESH_ATTEMPTS", "3"}])
    assert late == 0, output
    assert File.read!(Path.join(fixture, "polls")) == "3\n"
  end

  test "an existing PR that gh cannot read fails pre-pr" do
    fixture = fixture("unreadable-pr")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])
    File.write!(Path.join(fixture, "bin/gh"), "#!/usr/bin/env bash\necho 'HTTP 502: Bad Gateway' >&2\nexit 1\n")

    {output, status} = run_pre_pr(fixture, repo, gate_mode: "pass")

    assert status == 1
    assert output =~ "FAIL refresh-pr-body-evidence (could not read PR with gh)"
    assert output =~ "HTTP 502"
  end

  test "no PR yet skips the refresh and asks for a rerun after gh pr create" do
    fixture = fixture("no-pr")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])

    {output, status} = run_pre_pr(fixture, repo, gate_mode: "pass")

    assert status == 0
    assert output =~ "SKIP refresh-pr-body-evidence (no PR yet; rerun aiur pre-pr after gh pr create)"
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

    assert output =~
             "NOTE full selection (fixture requires full suite); running CI coverage partitions locally; full CI suite runs in merge queue"

    assert length(Regex.scan(~r/PASS coverage partition \([1-4]\/4\)/, output)) == 4

    assert File.read!(Path.join(fixture, "coverage-partitions")) ==
             "1:--max-cases 4\n2:--max-cases 4\n3:--max-cases 4\n4:--max-cases 4\n"

    assert output =~ "PASS reader tests"
    assert File.read!(Path.join(fixture, "reader-tests")) =~ "changed_reader_test.exs"
    refute File.read!(Path.join(fixture, "reader-tests")) =~ "changed_mention_test.exs"
    refute File.exists?(Path.join(fixture, "make-ci-ran"))
    assert File.read!(Path.join(fixture, "test-env")) == "clean\nclean\n"

    temp_dirs =
      fixture
      |> then(&Path.join(&1, "test-tmpdirs"))
      |> File.read!()
      |> String.split("\n", trim: true)

    assert length(temp_dirs) == 2
    assert Enum.all?(temp_dirs, &String.starts_with?(&1, Path.join(fixture, "aiur-pre-pr.")))
    assert output =~ "Result: FAIL"
    assert length(Regex.scan(~r/--- aiur pre-pr result/, output)) == 1

    assert :binary.match(output, "--- end aiur pre-pr result ---") <
             :binary.match(output, "format failure")

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

    File.write!(
      Path.join(repo, "src/test/dev_loop_reader_test.exs"),
      "File.read!(Path.join(skill, \"dev-loop.md\"))\n"
    )

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
    assert File.read!(Path.join(fixture, "nice-command")) =~ "-n 10"
  end

  test "shared support that selects no tests refuses pre-pr" do
    fixture = fixture("empty-support-selection")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])
    File.mkdir_p!(Path.join(repo, "src/test/support"))
    File.write!(Path.join(repo, "src/test/support/helper.exs"), "# shared support\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "change test support"])

    {output, status} = run_pre_pr(fixture, repo, selector_mode: "empty")

    assert status == 1
    assert output =~ "FAIL affected tests (shared support changed but no tests were selected)"
    assert output =~ "Result: FAIL"
  end

  test "reader failures identify test files the branch did not edit" do
    fixture = fixture("unedited-reader")
    repo = Path.join(fixture, "repo")
    File.mkdir_p!(Path.join(repo, "src/lib"))
    File.mkdir_p!(Path.join(repo, "src/test"))
    File.write!(Path.join(repo, "src/lib/changed.ex"), "base\n")

    File.write!(
      Path.join(repo, "src/test/unmodified_reader_test.exs"),
      "File.read!(\"src/lib/changed.ex\")\n"
    )

    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "base reader fixture"])
    git!(repo, ["switch", "-c", "feature"])
    File.write!(Path.join(repo, "src/lib/changed.ex"), "branch\n")
    git!(repo, ["commit", "-am", "edit source"])

    {output, status} = run_pre_pr(fixture, repo, reader_mode: "failure")

    assert status == 1
    assert output =~ "FAIL reader tests"

    assert output =~
             "NOTE failing test files not edited by this branch: src/test/unmodified_reader_test.exs"
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
    assert output =~ "Result: PASS (full CI suite not run)"
    assert output =~ "Not run: Credo and specs (make lint), dialyzer, full CI suite"
  end

  # The dev shim marks pre-pr as a retryable control command; its tests must not inherit that.
  test "pre-pr through the dev shim keeps control retry flags out of tests" do
    fixture = fixture("dev-shim")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])
    File.ln_s!(Path.expand("../../packaging", __DIR__), Path.join(repo, "packaging"))
    File.write!(Path.join(repo, ".git/info/exclude"), "/packaging\n")

    {output, _status} =
      System.cmd("bash", [@shim, "pre-pr"],
        cd: repo,
        env: [
          {"AIUR_REPO_ROOT", repo},
          {"AIUR_SKIP_BUILD", "1"},
          {"AIUR_AGENT_WORKSPACE", repo},
          {"AIUR_BASE_BRANCH", "main"},
          {"HOME", Path.join(fixture, "home")},
          {"TMPDIR", fixture},
          {"TMUX", nil},
          {"PATH", Path.join(fixture, "bin") <> ":" <> System.get_env("PATH")}
        ],
        stderr_to_stdout: true
      )

    assert output =~ "--- aiur pre-pr result"
    assert File.read!(Path.join(fixture, "test-env")) == "clean\n", output
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

    for script <- [
          "check-pr-structure.py",
          "check-file-size.py",
          "check-config-docs.py",
          "check-hot-list-format.py"
        ] do
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
        if [ -n "${AIUR_AGENT_WORKSPACE+x}${AIUR_INSTANCE_KEY+x}${AIUR_PROJECT_ROOT+x}${AIUR_CONTROL_RELEASE_RETRYABLE+x}${AIUR_CONTROL_RELEASE_RETRY_SIGNAL+x}" ]; then echo leaked > "#{root}/test-env"; exit 79; fi
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
          empty) echo '{"status":"scoped","tests":[]}' ;;
          scoped) echo '{"status":"scoped","tests":["src/test/scoped_test.exs"]}' ;;
          *) echo '{"status":"full","reason":"fixture requires full suite"}' ;;
        esac
        ;;
      *"make -C "*" coverage-partition"*)
        echo "$MIX_TEST_PARTITION:$MIX_TEST_ARGS" >> "#{root}/coverage-partitions"
        ;;
      *"make ci"*) echo yes > "#{root}/make-ci-ran"; exit 88 ;;
      *"mix format"*)
        if [ "${PRE_PR_GATE_MODE:-fail}" = pass ]; then exit 0; fi
        echo 'format failure'; exit 13
        ;;
      *) exit 0 ;;
    esac
    """

    gh = "#!/usr/bin/env bash\necho 'no pull requests found for branch \"feature\"' >&2\nexit 1\n"

    nice = """
    #!/usr/bin/env bash
    [[ "$1 $2" == "-n 10" ]] || exit 91
    echo "$*" >> "#{root}/nice-command"
    shift 2
    exec "$@"
    """

    for {name, contents} <- [{"mise", mise}, {"gh", gh}, {"nice", nice}] do
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

    command =
      "command() { if [ \"$1\" = -v ] && [ \"$2\" = \"${PRE_PR_MISSING_TOOL:-}\" ]; then return 1; fi; builtin command \"$@\"; }; source \"$AIUR_ENGINE\"; aiur_engine_main pre-pr"

    System.cmd("bash", ["-c", command],
      cd: repo,
      env: env,
      stderr_to_stdout: true
    )
  end

  defp run_refresh(fixture, repo, env) do
    File.rm(Path.join(fixture, "polls"))
    File.cp!(Path.join(fixture, "pr-seed.json"), Path.join(fixture, "pr.json"))

    System.cmd("bash", [Path.join(fixture, "refresh-wrapper.sh")],
      cd: repo,
      env:
        [
          {"PATH", Path.join(fixture, "bin") <> ":" <> System.get_env("PATH")},
          {"AIUR_PRE_PR_REFRESH_INTERVAL", "0"}
        ] ++ env,
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
