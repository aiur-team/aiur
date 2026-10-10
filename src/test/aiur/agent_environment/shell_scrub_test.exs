defmodule Aiur.AgentEnvironment.ShellScrubTest do
  # Not async: every test here mutates process-global `System.put_env` state
  # (including the ELEVENLABS_API_KEY credential case), which raced concurrent
  # BuildGate readers and made `AIUR_BUILD_START_STAGGER_SECONDS` observe another
  # module's value (#1920).
  use ExUnit.Case, async: false

  alias Aiur.AgentEnvironment

  test "identifies inherited Erlang distribution environment names" do
    assert AgentEnvironment.erlang_distribution_env_name?("ERL_AFLAGS")
    assert AgentEnvironment.erlang_distribution_env_name?("ERL_LIBS")
    assert AgentEnvironment.erlang_distribution_env_name?("RELEASE_NODE")
    assert AgentEnvironment.erlang_distribution_env_name?("RELEASE_COOKIE")
    assert AgentEnvironment.erlang_distribution_env_name?("AIUR_NODE_NAME")
    assert AgentEnvironment.erlang_distribution_env_name?("AIUR_AGENT_NODE_NAME")
    assert AgentEnvironment.erlang_distribution_env_name?("AIUR_COOKIE")
    assert AgentEnvironment.erlang_distribution_env_name?("AIUR_ERLANG_COOKIE")
    # Per-instance identity inputs (#431) must be scrubbed so an agent's inner aiur
    # derives its own identity instead of reaping the outer.
    assert AgentEnvironment.erlang_distribution_env_name?("AIUR_RELEASE_NODE")
    assert AgentEnvironment.erlang_distribution_env_name?("AIUR_INSTANCE_KEY")
    assert AgentEnvironment.erlang_distribution_env_name?("AIUR_REPO_ROOT")

    refute AgentEnvironment.erlang_distribution_env_name?("OTHER_COOKIE")
    refute AgentEnvironment.erlang_distribution_env_name?("PATH")
  end

  test "identifies inherited parent log environment names" do
    assert AgentEnvironment.parent_log_env_name?("AIUR_LOGS_ROOT")
    assert AgentEnvironment.parent_log_env_name?("AIUR_AGENT_IR_LOGS_PARENT")

    refute AgentEnvironment.parent_log_env_name?("AIUR_AGENT_WORKSPACE")
    refute AgentEnvironment.parent_log_env_name?("AIUR_DEBUG")
  end

  test "scrub_shell_command clears Erlang distribution environment before exec" do
    command =
      AgentEnvironment.scrub_shell_command(
        "env | grep -E '^(ERL_AFLAGS|ERL_LIBS|ERL_CRASH_DUMP|ERL_CRASH_DUMP_SECONDS|RELEASE_NODE|RELEASE_COOKIE|AIUR_NODE_NAME|AIUR_AGENT_NODE_NAME|AIUR_COOKIE|AIUR_ERLANG_COOKIE|AIUR_RELEASE_NODE|AIUR_INSTANCE_KEY|AIUR_REPO_ROOT|ROOTDIR|BINDIR|EMU|PROGNAME|OTHER_COOKIE)=' | sort"
      )

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"ERL_AFLAGS", "-name aiur@test"},
          {"ERL_LIBS", "/outer/release/lib"},
          {"ERL_CRASH_DUMP", "/outer/log/erl_crash.dump"},
          {"ERL_CRASH_DUMP_SECONDS", "30"},
          {"RELEASE_NODE", "aiur@test"},
          {"RELEASE_COOKIE", "secret"},
          {"AIUR_NODE_NAME", "aiur@test"},
          {"AIUR_AGENT_NODE_NAME", "aiur@test"},
          {"AIUR_COOKIE", "secret"},
          {"AIUR_ERLANG_COOKIE", "secret"},
          # #431 per-instance identity inputs — must not leak into an inner aiur.
          {"AIUR_RELEASE_NODE", "aiur-kevin-abc1230000@127.0.0.1"},
          {"AIUR_INSTANCE_KEY", "abc1230000"},
          {"AIUR_REPO_ROOT", "/outer/repo"},
          {"AIUR_RELEASE_DIR", "/outer/release"},
          {"ROOTDIR", "/outer/release"},
          {"BINDIR", "/outer/release/erts-16.4/bin"},
          {"EMU", "beam"},
          {"PROGNAME", "erl"},
          {"OTHER_COOKIE", "keep"}
        ]
      )

    assert output == "OTHER_COOKIE=keep\n"
  end

  test "scrub_shell_command can retain an Aiur-owned build hook" do
    command = AgentEnvironment.scrub_shell_command("printf ready", trusted_bash_env: true)

    refute command =~ "unset BASH_ENV"
    assert command =~ "unset ENV"
  end

  test "scrub_shell_command clears the restart rebuild command bound to the outer checkout" do
    # AIUR_RESTART_BUILD_CMD names one checkout's builder. Inherited by an agent,
    # an inner `aiur restart` runs the OUTER checkout's rebuild against whatever
    # release it is pointed at — the cross-checkout build this guard exists to end.
    command =
      AgentEnvironment.scrub_shell_command("env | grep -E '^(AIUR_RESTART_BUILD_CMD|AIUR_RESTART_BUILD_RECEIPT|AIUR_RESTART_BUILD_VERIFIES|OTHER_KEEP)=' | sort")

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RESTART_BUILD_CMD", "AIUR_REPO_ROOT=/outer/repo /outer/repo/scripts/aiurdev __ensure-build"},
          {"AIUR_RESTART_BUILD_RECEIPT", "/tmp/outer-receipt"},
          {"AIUR_RESTART_BUILD_VERIFIES", "1"},
          {"OTHER_KEEP", "keep"}
        ]
      )

    assert output == "OTHER_KEEP=keep\n"
  end

  test "scrubbed toolchain probe resolves OTP from mise, not the release" do
    release_root = Aiur.TestSupport.tmp_root!("aiur-release")
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
    release_bin = Path.join(release_root, "bin")
    expected_inets = :inets |> :code.lib_dir() |> to_string()
    File.mkdir_p!(release_erts_bin)
    File.mkdir_p!(release_bin)
    File.write!(Path.join(release_erts_bin, "erl"), "#!/bin/sh\necho poisoned-release-erl\nexit 86\n")
    File.chmod!(Path.join(release_erts_bin, "erl"), 0o755)
    on_exit(fn -> File.rm_rf!(release_root) end)

    command =
      AgentEnvironment.scrub_shell_command("mise exec -- elixir -e 'IO.puts(:code.lib_dir(:inets)); IO.inspect(Application.ensure_all_started(:inets))'")

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RELEASE_DIR", release_root},
          {"ROOTDIR", release_root},
          {"BINDIR", release_erts_bin},
          {"EMU", "beam"},
          {"PROGNAME", "erl"},
          {"PATH", Enum.join([release_erts_bin, release_bin, System.fetch_env!("PATH")], ":")}
        ]
      )

    assert output =~ expected_inets
    assert output =~ "{:ok, [:inets]}"
    refute output =~ release_root
  end

  test "scrub_shell_command preserves unrelated launcher variables and PATH entries" do
    command =
      AgentEnvironment.scrub_shell_command(~s(printf '%s\n%s\n%s\n%s\n%s' "$ROOTDIR" "$BINDIR" "$EMU" "$PROGNAME" "$PATH"))

    unrelated_path = "/opt/user-otp/bin:/usr/local/bin:/usr/bin"

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RELEASE_DIR", "/opt/aiur/release"},
          {"ROOTDIR", "/opt/user-otp"},
          {"BINDIR", "/opt/user-otp/bin"},
          {"EMU", "custom-beam"},
          {"PROGNAME", "custom-erl"},
          {"PATH", unrelated_path},
          {"AIUR_AGENT_BIN", ""}
        ]
      )

    assert ["/opt/user-otp", "/opt/user-otp/bin", "custom-beam", "custom-erl", path] =
             String.split(output, "\n")

    # Login shells may prepend the agent command-guard directory and append
    # system defaults; the caller's unrelated entries must survive in order.
    unrelated_entries = String.split(unrelated_path, ":")
    assert Enum.filter(String.split(path, ":"), &(&1 in unrelated_entries)) == unrelated_entries
  end

  test "scrub_shell_command puts the build gate before other agent commands" do
    command = AgentEnvironment.scrub_shell_command(~s(printf '%s' "$PATH"))

    assert {path, 0} =
             System.cmd("bash", ["-lc", command],
               env: [
                 {"AIUR_BUILD_GATE_BIN", "/workspace/build-bin"},
                 {"AIUR_AGENT_BIN", "/workspace/agent-bin"},
                 {"PATH", "/usr/bin"}
               ]
             )

    assert String.starts_with?(path, "/workspace/build-bin:/workspace/agent-bin:")
  end

  test "scrub_shell_command tracks mixed launcher ownership independently" do
    release_root = "/opt/aiur/release"
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
    user_bin = "/opt/user-otp/bin"

    command =
      AgentEnvironment.scrub_shell_command(~s(printf '%s\n%s\n%s\n%s\n%s' "$ROOTDIR" "$BINDIR" "$EMU" "$PROGNAME" "$PATH"))

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RELEASE_DIR", release_root},
          {"ROOTDIR", release_root},
          {"BINDIR", user_bin},
          {"EMU", "custom-beam"},
          {"PROGNAME", "custom-erl"},
          {"PATH", Enum.join([release_erts_bin, user_bin, "/usr/bin"], ":")}
        ]
      )

    assert ["", ^user_bin, "custom-beam", "custom-erl", path] = String.split(output, "\n")
    refute path =~ release_erts_bin
    assert path =~ user_bin
  end

  test "scrub_shell_command removes release PATH entries without owned root or bindir" do
    release_root = "/opt/aiur/release"
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
    release_bin = Path.join(release_root, "bin")
    user_root = "/opt/user-otp"
    user_bin = Path.join(user_root, "bin")

    command =
      AgentEnvironment.scrub_shell_command(~s(printf '%s\n%s\n%s\n%s\n%s' "$ROOTDIR" "$BINDIR" "$EMU" "$PROGNAME" "$PATH"))

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RELEASE_DIR", release_root},
          {"ROOTDIR", user_root},
          {"BINDIR", user_bin},
          {"EMU", "beam"},
          {"PROGNAME", "erl"},
          {"PATH", Enum.join([release_erts_bin, release_bin, user_bin, "/usr/bin"], ":")}
        ]
      )

    # ROOTDIR/BINDIR are user values here, so EMU/PROGNAME (`beam`/`erl`) are
    # NOT release-owned either and must survive — only the PATH cleanup is
    # unconditional once AIUR_RELEASE_DIR establishes the boundary.
    assert [^user_root, ^user_bin, "beam", "erl", path] = String.split(output, "\n")
    refute path =~ release_root
    assert path =~ user_bin
  end

  test "scrub_shell_command scrubs EMU/PROGNAME only when the release launcher owns them" do
    release_root = "/opt/aiur/release"
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])

    command =
      AgentEnvironment.scrub_shell_command(~s(printf '%s\n%s\n%s\n%s' "$ROOTDIR" "$BINDIR" "$EMU" "$PROGNAME"))

    # EMU=beam/PROGNAME=erl are generic values; with unrelated ROOTDIR/BINDIR
    # they are user values and must survive the scrub.
    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RELEASE_DIR", release_root},
          {"ROOTDIR", "/opt/user-otp"},
          {"BINDIR", "/opt/user-otp/bin"},
          {"EMU", "beam"},
          {"PROGNAME", "erl"}
        ]
      )

    assert output == "/opt/user-otp\n/opt/user-otp/bin\nbeam\nerl"

    # Once ROOTDIR or BINDIR is release-owned, EMU/PROGNAME at the canonical
    # values belong to the release and are scrubbed.
    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RELEASE_DIR", release_root},
          {"ROOTDIR", release_root},
          {"BINDIR", release_erts_bin},
          {"EMU", "beam"},
          {"PROGNAME", "erl"}
        ]
      )

    assert output == "\n\n\n"
  end

  test "scrub_shell_command removes trailing-slash release BINDIR and PATH entries" do
    release_root = "/opt/aiur/release"
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
    release_bin = Path.join(release_root, "bin")
    user_bin = "/opt/user-otp/bin"

    command =
      AgentEnvironment.scrub_shell_command(~s(printf '%s\n%s\n%s\n%s\n%s' "$ROOTDIR" "$BINDIR" "$EMU" "$PROGNAME" "$PATH"))

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_RELEASE_DIR", release_root},
          {"ROOTDIR", release_root},
          {"BINDIR", release_erts_bin <> "/"},
          {"EMU", "beam"},
          {"PROGNAME", "erl"},
          {"PATH", Enum.join([release_erts_bin <> "/", release_bin <> "/", user_bin, "/usr/bin"], ":")}
        ]
      )

    # BINDIR with a trailing slash is still release-owned; trailing-slash PATH
    # entries still get filtered, while unrelated user entries are preserved.
    assert ["", "", "", "", path] = String.split(output, "\n")
    refute path =~ release_root
    assert path =~ user_bin
    assert path =~ "/usr/bin"
  end

  test "release launcher scrub runs under a POSIX sh interpreter" do
    release_root = "/opt/aiur/release"
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
    release_bin = Path.join(release_root, "bin")
    user_bin = "/opt/user-otp/bin"

    # The release launcher block must stay POSIX-sh portable (dash on Debian
    # CI); `dash` is not installed on every host, so fall back to the system
    # POSIX sh.
    interpreter = System.find_executable("dash") || System.find_executable("sh") || "sh"

    command =
      AgentEnvironment.scrub_shell_command(~s(printf '%s\n%s\n%s\n%s\n%s' "$ROOTDIR" "$BINDIR" "$EMU" "$PROGNAME" "$PATH"))

    {output, 0} =
      System.cmd(interpreter, ["-c", command],
        env: [
          {"AIUR_RELEASE_DIR", release_root},
          {"ROOTDIR", release_root},
          {"BINDIR", release_erts_bin},
          {"EMU", "beam"},
          {"PROGNAME", "erl"},
          {"PATH", Enum.join([release_erts_bin, release_bin, user_bin, "/usr/bin"], ":")}
        ]
      )

    assert ["", "", "", "", path] = String.split(output, "\n")
    refute path =~ release_root
    assert path =~ user_bin
  end

  test "scrub_shell_command clears parent log environment before exec" do
    grep_pattern =
      "^(AIUR_LOGS_ROOT|AIUR_AGENT_IR_LOGS_PARENT|AIUR_CI_READINESS_TOKEN|AIUR_AGENT_WORKSPACE|AIUR_DEBUG)="

    command =
      AgentEnvironment.scrub_shell_command("env | grep -E '#{grep_pattern}' | sort")

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"AIUR_LOGS_ROOT", "/home/operator/.aiur/logs/live-session"},
          {"AIUR_AGENT_IR_LOGS_PARENT", "/home/operator/.aiur/logs"},
          {"AIUR_CI_READINESS_TOKEN", "operator-only"},
          {"AIUR_AGENT_WORKSPACE", "/work/aiur/697"},
          {"AIUR_DEBUG", "1"}
        ]
      )

    assert output == "AIUR_AGENT_WORKSPACE=/work/aiur/697\nAIUR_DEBUG=1\n"
  end

  # #2356: the raw GitHub credential must not survive into an agent process.
  # A PAT in the environment authenticates any direct-HTTP process (curl, Req,
  # python, node) unmetered and untraced; the guard now reads the credential
  # from a file the daemon writes and injects it only into a governed call.
  test "scrub_shell_command clears provider API keys and the raw GitHub credential" do
    command =
      AgentEnvironment.scrub_shell_command(
        "env | grep -E '^(DEEPSEEK_API_KEY|DEEPSEEK_API_KEY__WORK|OPENROUTER_API_KEY|OPENROUTER_MANAGEMENT_KEY|GITHUB_TOKEN|GH_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN)=' | sort"
      )

    {output, 0} =
      System.cmd("bash", ["-lc", command],
        env: [
          {"DEEPSEEK_API_KEY", "deepseek-secret"},
          {"DEEPSEEK_API_KEY__WORK", "named-deepseek-secret"},
          {"OPENROUTER_API_KEY", "openrouter-secret"},
          {"OPENROUTER_MANAGEMENT_KEY", "management-secret"},
          {"GITHUB_TOKEN", "tracker-token"},
          {"GH_TOKEN", "gh-token"},
          {"GH_ENTERPRISE_TOKEN", "enterprise-gh-token"},
          {"GITHUB_ENTERPRISE_TOKEN", "enterprise-github-token"}
        ]
      )

    assert output == ""
  end

  # ELEVENLABS_API_KEY is the Stream Deck voice-input credential the daemon reads.
  # It ends in `_API_KEY`, so all three scrub surfaces already cover it; this is
  # the regression guard that keeps it that way.

  test "shell startup suppression clears profile hooks" do
    assert AgentEnvironment.shell_startup_env() == [{"BASH_ENV", false}, {"ENV", false}, {"ZDOTDIR", "/dev/null"}]
    assert AgentEnvironment.shell_startup_prefix() == "unset BASH_ENV ENV; export ZDOTDIR='/dev/null'"
    assert AgentEnvironment.shell_startup_env_name?("BASH_ENV")
    assert AgentEnvironment.shell_startup_env_name?(~c"ZDOTDIR")
    refute AgentEnvironment.shell_startup_env_name?("HOME")
  end

  test "System.cmd startup suppression uses nil, not false, and survives System.cmd" do
    assert AgentEnvironment.system_shell_startup_env() ==
             [{"BASH_ENV", nil}, {"ENV", nil}, {"ZDOTDIR", "/dev/null"}]

    # System.validate_env/1 raises FunctionClauseError on a `false` value, so
    # this asserts the shape is actually accepted by the call sites that use it.
    assert {"/dev/null\n", 0} =
             System.cmd("sh", ["-c", "printf '%s\\n' \"${ZDOTDIR:-unset}\""],
               env: AgentEnvironment.system_shell_startup_env(),
               stderr_to_stdout: true
             )
  end

  test "scrub_shell_command preserves caller exec choice" do
    refute AgentEnvironment.scrub_shell_command("codex app-server") =~ "; exec codex"
    assert AgentEnvironment.scrub_shell_command("codex app-server", exec: true) =~ "; exec codex app-server"
  end

  # The prewarm base build is a daemon-owned operation, not an agent scope: the
  # operator's configured build command (e.g. `mix deps.get`) keeps whatever
  # auth it already had, so the GitHub credential scrub is opt-out there.
  test "scrub_shell_command can keep the GitHub credential for daemon-owned builds" do
    command =
      AgentEnvironment.scrub_shell_command(
        "env | grep -E '^(GITHUB_TOKEN|GH_TOKEN)=' | sort",
        github_credential: false
      )

    {output, 0} =
      System.cmd("bash", ["-lc", command], env: [{"GITHUB_TOKEN", "tracker-token"}, {"GH_TOKEN", "gh-token"}])

    assert output == "GH_TOKEN=gh-token\nGITHUB_TOKEN=tracker-token\n"
  end
end
