defmodule AiurEngineOneshotTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "load_dotenv reads ./.env, strips quotes, and lets shell exports win" do
    dir = Aiur.TestSupport.tmp_root!("aiur-env")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), "# token\nGITHUB_TOKEN=fromfile\nFOO=\"bar baz\"\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    src = "cd #{dir}; source #{engine()}; load_dotenv; echo \"TOK=$GITHUB_TOKEN|FOO=$FOO\""

    {out, 0} =
      System.cmd("bash", ["-c", src],
        env: [{"GITHUB_TOKEN", nil}, {"FOO", nil}],
        stderr_to_stdout: true
      )

    assert out =~ "TOK=fromfile|FOO=bar baz"

    # A value already in the environment is never clobbered by the file.
    {out2, 0} = System.cmd("bash", ["-c", "export GITHUB_TOKEN=shell; #{src}"], stderr_to_stdout: true)
    assert out2 =~ "TOK=shell|"
  end

  # #2638: `./.env` is the more specific scope, so it loads before
  # `~/.aiur/.env`, and GitHub credentials resolve as one group from the first
  # file that declares any member. A global GITHUB_APP_* triple must never
  # fill the gaps around a repo-local GITHUB_TOKEN and outrank it.
  describe "load_dotenv precedence between ~/.aiur/.env and ./.env" do
    setup do
      root = Aiur.TestSupport.tmp_root!("aiur-env-precedence")
      home = Path.join(root, "home")
      repo = Path.join(root, "repo")
      File.mkdir_p!(Path.join(home, ".aiur"))
      File.mkdir_p!(repo)
      on_exit(fn -> File.rm_rf!(root) end)

      File.write!(
        Path.join(home, ".aiur/.env"),
        "GITHUB_APP_ID=global-app\nGITHUB_APP_INSTALLATION_ID=global-install\n" <>
          "GITHUB_APP_PRIVATE_KEY_PATH=/global/key.pem\nGITHUB_TOKEN=global-token\nOTHER=global-other\n"
      )

      %{home: home, repo: repo}
    end

    defp load_env_report(home, repo, extra_env \\ []) do
      args =
        Enum.map_join(
          ~w(GITHUB_TOKEN GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_PATH OTHER),
          " ",
          &~s("${#{&1}-unset}")
        )

      src =
        "cd #{repo}; source #{engine()}; load_dotenv; " <>
          "printf 'TOK=%s|APP=%s|INST=%s|KEY=%s|OTHER=%s' #{args}"

      cleared =
        Enum.map(
          ~w(GITHUB_TOKEN GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_PATH GITHUB_APP_PRIVATE_KEY OTHER),
          &{&1, nil}
        )

      {out, 0} = System.cmd("bash", ["-c", src], env: cleared ++ [{"HOME", home}] ++ extra_env, stderr_to_stdout: true)
      out
    end

    test "a repo-local GITHUB_TOKEN suppresses the global GITHUB_APP_* triple", %{home: home, repo: repo} do
      File.write!(Path.join(repo, ".env"), "GITHUB_TOKEN=repo-token\n")

      assert load_env_report(home, repo) ==
               "TOK=repo-token|APP=unset|INST=unset|KEY=unset|OTHER=global-other"
    end

    test "a repo-local GITHUB_TOKEN wins over a different global GITHUB_TOKEN", %{home: home, repo: repo} do
      File.write!(Path.join(home, ".aiur/.env"), "GITHUB_TOKEN=global-token\nOTHER=global-other\n")
      File.write!(Path.join(repo, ".env"), "GITHUB_TOKEN=repo-token\nOTHER=repo-other\n")

      assert load_env_report(home, repo) == "TOK=repo-token|APP=unset|INST=unset|KEY=unset|OTHER=repo-other"
    end

    test "a real shell export outranks both files", %{home: home, repo: repo} do
      File.write!(Path.join(repo, ".env"), "GITHUB_TOKEN=repo-token\n")

      assert load_env_report(home, repo, [{"GITHUB_TOKEN", "shell-token"}, {"GITHUB_APP_ID", "shell-app"}]) ==
               "TOK=shell-token|APP=shell-app|INST=unset|KEY=unset|OTHER=global-other"
    end

    test "an empty or absent repo .env leaves the global App in force", %{home: home, repo: repo} do
      expected = "TOK=global-token|APP=global-app|INST=global-install|KEY=/global/key.pem|OTHER=global-other"

      File.write!(Path.join(repo, ".env"), "# nothing here\n")
      assert load_env_report(home, repo) == expected

      File.rm!(Path.join(repo, ".env"))
      assert load_env_report(home, repo) == expected
    end

    # `aiur init` scaffolds `GITHUB_TOKEN=` and `.env.example` renders every
    # name blank. A blank value is a placeholder, so it must neither shadow the
    # global value of the same name nor count as declaring the credential group.
    test "a blank placeholder GITHUB_TOKEN= line does not shadow the global credentials", %{home: home, repo: repo} do
      File.write!(Path.join(repo, ".env"), "GITHUB_TOKEN=\nOTHER=\"\"\n")

      assert load_env_report(home, repo) ==
               "TOK=global-token|APP=global-app|INST=global-install|KEY=/global/key.pem|OTHER=global-other"
    end
  end

  test "run-only environment scrub removes the operator readiness token" do
    dir = Aiur.TestSupport.tmp_root!("aiur-readiness-env")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), "AIUR_CI_READINESS_TOKEN=operator-only\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    src =
      "cd #{dir}; source #{engine()}; load_dotenv; " <>
        "printf 'LOADED=%s|' \"$AIUR_CI_READINESS_TOKEN\"; " <>
        "scrub_run_only_env; printf 'RUN=%s' \"${AIUR_CI_READINESS_TOKEN-unset}\""

    {out, 0} =
      System.cmd("bash", ["-c", src],
        env: [{"AIUR_CI_READINESS_TOKEN", nil}],
        stderr_to_stdout: true
      )

    assert out =~ "LOADED=operator-only|RUN=unset"

    engine = Aiur.EngineSource.text()
    assert engine =~ ~r/load_dotenv\s+scrub_run_only_env/
    assert engine =~ "printf 'unset AIUR_CI_READINESS_TOKEN\\n'"
  end

  test "init intentionally retains the operator readiness token" do
    rel = fake_release()
    state = Aiur.TestSupport.tmp_root!("aiur-init-token")
    elixir = Path.join([rel, "releases", "0.1.1", "elixir"])

    File.write!(elixir, "#!/usr/bin/env bash\nprintf 'CI_TOKEN=%s\\n' \"${AIUR_CI_READINESS_TOKEN-unset}\"\n")

    on_exit(fn ->
      File.rm_rf!(rel)
      File.rm_rf!(state)
    end)

    {out, 0} =
      run_engine(["init"], [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"AIUR_CI_READINESS_TOKEN", "operator-only"}
      ])

    assert out =~ "CI_TOKEN=operator-only"
  end

  test "an unknown command exits 64 with usage" do
    {out, code} = run_engine(["bogus-not-a-path"], [])
    assert code == 64
    assert out =~ "unknown command"
    refute out =~ "installed CLI"
  end

  test "an unknown command diagnoses a dispatcher older than its stamped checkout" do
    root = Aiur.TestSupport.tmp_root!("aiur-stale-cli")
    installed_libexec = Path.join([root, "installed", "libexec"])
    checkout_package = Path.join([root, "checkout", "packaging", "npm", "aiur-cli"])
    release = Path.join(root, "release")

    File.mkdir_p!(installed_libexec)
    File.mkdir_p!(checkout_package)
    File.mkdir_p!(release)
    File.write!(Path.join(root, "installed/package.json"), "{\n  \"version\": \"1.2.3\"\n}\n")
    File.write!(Path.join(checkout_package, "package.json"), "{\n  \"version\": \"1.3.0\"\n}\n")
    File.write!(Path.join(release, "AIUR_BUILD_STAMP"), "repo_root=#{Path.join(root, "checkout")}\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      run_sourced_engine(
        ~S|engine_dir="$INSTALLED_LIBEXEC"; aiur_engine_main bogus-not-a-path|,
        [{"INSTALLED_LIBEXEC", installed_libexec}, {"AIUR_RELEASE_DIR", release}]
      )

    assert code == 64
    assert out =~ "installed CLI 1.2.3 is older than checkout CLI 1.3.0"
    assert out =~ "update aiur-cli before retrying"
    assert out =~ "Usage: aiur"
  end

  test "stale dispatcher diagnosis supports prerelease versions" do
    root = Aiur.TestSupport.tmp_root!("aiur-stale-prerelease-cli")
    installed_libexec = Path.join([root, "installed", "libexec"])
    checkout_package = Path.join([root, "checkout", "packaging", "npm", "aiur-cli"])
    release = Path.join(root, "release")

    File.mkdir_p!(installed_libexec)
    File.mkdir_p!(checkout_package)
    File.mkdir_p!(release)

    File.write!(
      Path.join(root, "installed/package.json"),
      "{\n  \"version\": \"1.2.3-nightly.abcdef0+local\"\n}\n"
    )

    File.write!(Path.join(checkout_package, "package.json"), "{\n  \"version\": \"1.2.3\"\n}\n")
    File.write!(Path.join(release, "AIUR_BUILD_STAMP"), "repo_root=#{Path.join(root, "checkout")}\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      run_sourced_engine(
        ~S|engine_dir="$INSTALLED_LIBEXEC"; aiur_engine_main bogus-not-a-path|,
        [{"INSTALLED_LIBEXEC", installed_libexec}, {"AIUR_RELEASE_DIR", release}]
      )

    assert code == 64
    assert out =~ "installed CLI 1.2.3-nightly.abcdef0+local is older than checkout CLI 1.2.3"
    assert out =~ "Usage: aiur"
  end

  test "version comparison warns only when the installed CLI is older" do
    {out, 0} =
      run_sourced_engine(
        """
        version_is_older 1.2.3 1.2.3 && echo equal-older || true
        version_is_older 1.2.4 1.2.3 && echo newer-older || true
        version_is_older 1.2.3 1.2.4 && echo patch-older
        version_is_older 1.2.3-nightly.aaaaaaa 1.2.3-nightly.bbbbbbb && echo prerelease-older
        version_is_older not-semver 1.2.3 && echo malformed-older || true
        """,
        []
      )

    assert out =~ "patch-older"
    assert out =~ "prerelease-older"
    refute out =~ "equal-older"
    refute out =~ "newer-older"
    refute out =~ "malformed-older"
  end

  test "init boots interactively and distribution-free (no --name/--cookie)" do
    rel = fake_release()
    state = Aiur.TestSupport.tmp_root!("aiur-st")

    {out, _} = run_engine(["init"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])

    assert out =~ "--eval"
    assert out =~ "Aiur.CLI.main(Aiur.CLI.argv_from_file())"
    refute out =~ "--name"
    refute out =~ "--cookie"
  end

  test "todo routes through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\nrun_todo --todo 11 012,13 --only|,
        []
      )

    assert out =~
             "RPC:Aiur.AgentControlCLI.todo([\"11\", \"12\", \"13\"], only: true, budget_ms: 104000, emit_exit_marker: true)"
  end

  # #2519: the shared 10s control budget killed `--todo … --only` every time,
  # because its work is proportional to the request and to the tracker's queue
  # depth rather than to daemon state. The watchdog must scale with that work,
  # and the daemon's own budget must stay strictly inside the watchdog so its
  # summary is never the thing that gets discarded.
  test "todo sizes its rpc watchdog to the requested work and stays inside it" do
    for {argv, expected_timeout, expected_budget_ms} <- [
          {"--todo 11", 18, 8000},
          {"--todo 11 12 13", 24, 14_000},
          {"--todo 11 --only", 108, 98_000},
          {"--todo 1 2 3 5 --only", 117, 107_000}
        ] do
      {out, 0} =
        run_sourced_engine(
          ~s|run_control_rpc() { echo "TIMEOUT:$AIUR_CONTROL_RPC_TIMEOUT_SECONDS"; echo "RPC:$1"; }\nrun_todo #{argv}|,
          []
        )

      assert out =~ "TIMEOUT:#{expected_timeout}"
      assert out =~ "budget_ms: #{expected_budget_ms}"
    end
  end

  test "an explicit todo timeout override wins and still bounds the daemon" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "TIMEOUT:$AIUR_CONTROL_RPC_TIMEOUT_SECONDS"; echo "RPC:$1"; }\nrun_todo --todo 11 --only|,
        [{"AIUR_CONTROL_RPC_TIMEOUT_SECONDS", "300"}]
      )

    assert out =~ "TIMEOUT:300"
    assert out =~ "budget_ms: 290000"
  end

  # An override shorter than the grace window must still produce a positive
  # budget: a zero or negative one would read as "unlimited" on the daemon side
  # and put us straight back to a watchdog kill with an unknown outcome. An
  # unusable override falls back to work-proportional sizing rather than to the
  # shared 10s default, which is the very budget #2519 is about.
  test "a todo timeout override below the grace window still bounds the daemon" do
    for {override, expected_timeout, expected_budget_ms} <- [{"3", 3, 1000}, {"0", 18, 8000}, {"bogus", 18, 8000}, {"", 18, 8000}] do
      {out, 0} =
        run_sourced_engine(
          ~s|run_control_rpc() { echo "TIMEOUT:$AIUR_CONTROL_RPC_TIMEOUT_SECONDS"; echo "RPC:$1"; }\nrun_todo --todo 11|,
          [{"AIUR_CONTROL_RPC_TIMEOUT_SECONDS", override}]
        )

      assert out =~ "TIMEOUT:#{expected_timeout}"
      assert out =~ "budget_ms: #{expected_budget_ms}"
    end
  end
end
