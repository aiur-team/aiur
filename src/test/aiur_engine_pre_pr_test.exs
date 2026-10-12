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
        case "$*" in *changed_reader_test.exs*) echo "$*" > "#{root}/reader-tests" ;; esac
        ;;
    esac
    case "$*" in
      *"mix aiur.affected_tests"*) echo '{"status":"full","reason":"fixture requires full suite"}' ;;
      *"make ci"*) echo yes > "#{root}/make-ci-ran"; exit 88 ;;
      *"mix format"*) echo 'format failure'; exit 13 ;;
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

  defp run_pre_pr(fixture, repo) do
    env = [
      {"AIUR_ENGINE", @engine},
      {"AIUR_AGENT_WORKSPACE", repo},
      {"AIUR_BASE_BRANCH", "main"},
      {"HOME", Path.join(fixture, "home")},
      {"TMPDIR", fixture},
      {"PATH", Path.join(fixture, "bin") <> ":" <> System.get_env("PATH")}
    ]

    System.cmd("bash", ["-c", "source \"$AIUR_ENGINE\"; aiur_engine_main pre-pr"],
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
