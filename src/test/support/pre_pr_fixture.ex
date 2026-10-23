defmodule Aiur.PrePrFixture do
  @moduledoc false
  import ExUnit.Assertions, only: [flunk: 1]
  import ExUnit.Callbacks, only: [on_exit: 1]

  @engine Path.expand("../../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  def fixture(name) do
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

  # Records the pre-pr shell's pid in `<fixture>/pre-pr.pid` so a fake tool can
  # signal exactly that process instead of walking a platform-dependent ppid chain.
  def run_pre_pr(fixture, repo, opts \\ []) do
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
      "echo $$ > \"#{fixture}/pre-pr.pid\"; command() { if [ \"$1\" = -v ] && [ \"$2\" = \"${PRE_PR_MISSING_TOOL:-}\" ]; then return 1; fi; builtin command \"$@\"; }; source \"$AIUR_ENGINE\"; aiur_engine_main pre-pr"

    System.cmd("bash", ["-c", command],
      cd: repo,
      env: env,
      stderr_to_stdout: true
    )
  end

  def git!(repo, args) do
    {output, status} =
      System.cmd("git", args,
        cd: repo,
        env: [{"AIUR_AGENT_WORKSPACE", repo}],
        stderr_to_stdout: true
      )

    if status != 0, do: flunk("git #{Enum.join(args, " ")} failed: #{output}")
    output
  end
end
