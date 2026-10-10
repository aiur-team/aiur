defmodule AiurEngineUpgradeTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  @live_dist_tags ~s({"latest":"0.0.3","next":"0.0.4","nightly":"0.0.5-nightly.9540a62"})

  # A fake `npm` on PATH: `view` cats the canned dist-tags; `install` records the
  # args and rewrites the version file so `cli_package_version` (overridden below)
  # reflects the "after" version. No real network, no real global install.
  defp fake_npm_bin(_tags_file, _version_file) do
    bin = Aiur.TestSupport.tmp_root!("aiur-fake-npm")
    File.mkdir_p!(bin)
    npm = Path.join(bin, "npm")

    File.write!(
      npm,
      """
      #!/usr/bin/env bash
      if [ "${1:-}" = "view" ]; then cat "$AIUR_TAGS_FILE"; exit 0; fi
      if [ "${1:-}" = "install" ]; then
        printf '%s\\n' "$AIUR_UPGRADE_AFTER" > "$AIUR_VERSION_FILE"
        printf 'npm install args: %s\\n' "$*" >> "$AIUR_NPM_LOG"
        exit 0
      fi
      exit 1
      """
    )

    File.chmod!(npm, 0o755)
    on_exit(fn -> File.rm_rf!(bin) end)
    bin
  end

  defp upgrade_env(tags \\ @live_dist_tags, version \\ "0.0.3") do
    state = tmp_state()
    tags_file = Aiur.TestSupport.tmp_root!("aiur-tags")
    version_file = Aiur.TestSupport.tmp_root!("aiur-ver")
    npm_log = Aiur.TestSupport.tmp_root!("aiur-npm")
    File.write!(tags_file, tags)
    File.write!(version_file, version)
    File.write!(npm_log, "")

    on_exit(fn ->
      File.rm(state)
      File.rm(tags_file)
      File.rm(version_file)
      File.rm(npm_log)
    end)

    bin = fake_npm_bin(tags_file, version_file)

    %{
      state: state,
      tags_file: tags_file,
      version_file: version_file,
      npm_log: npm_log,
      npm_bin: bin
    }
  end

  # Run `cmd_upgrade` with the release/daemon/npm surfaces stubbed. `mock` lets a
  # test override the defaults (e.g. probe up, aiur_install_method brew, or an
  # after-version).
  defp run_upgrade(fixture, args \\ "", mock \\ "", after_version \\ "0.0.4") do
    script = """
    resolve_release() { :; }
    prepare_distribution() { :; }
    probe_control_liveness() { printf down; }
    aiur_install_method() { printf npm; }
    cli_package_version() { cat "$AIUR_VERSION_FILE"; }
    #{mock}
    cmd_upgrade #{args}
    """

    run_sourced_engine(script, [
      {"AIUR_BG_STATE_DIR", fixture.state},
      {"AIUR_TAGS_FILE", fixture.tags_file},
      {"AIUR_VERSION_FILE", fixture.version_file},
      {"AIUR_NPM_LOG", fixture.npm_log},
      {"AIUR_UPGRADE_AFTER", after_version},
      {"PATH", "#{fixture.npm_bin}:/usr/bin:/bin"}
    ])
  end

  test "usage advertises aiur upgrade" do
    {out, 0} = run_sourced_engine("usage", [])
    assert out =~ "aiur upgrade"
  end

  test "upgrade refuses in a development checkout (aiurdev), changing nothing" do
    fixture = upgrade_env()
    state_file = Path.join(fixture.state, "upgrade.json")

    {out, code} =
      run_sourced_engine(
        "cmd_upgrade",
        [
          {"AIUR_BG_STATE_DIR", fixture.state},
          {"AIUR_RELEASE_DIR", "/repo/src/_build/dev/rel/aiur"}
        ]
      )

    assert code != 0
    assert out =~ "cannot run from a development checkout"
    assert out =~ "aiurdev"
    assert out =~ "nothing has been changed"
    refute File.exists?(state_file)
  end

  test "upgrade refuses a Homebrew install (releases are npm-only right now)" do
    fixture = upgrade_env()

    {out, code} = run_upgrade(fixture, "", "aiur_install_method() { printf brew; }")

    assert code != 0
    assert out =~ "does not support Homebrew installs"
    assert out =~ "npm-only"
  end

  test "upgrade refuses when it cannot determine the install method" do
    fixture = upgrade_env()

    {out, code} = run_upgrade(fixture, "", "aiur_install_method() { printf unknown; }")

    assert code != 0
    assert out =~ "could not determine how it was installed"
    assert out =~ "refused to guess"
  end

  test "upgrade refuses while a daemon is running (no --force)" do
    fixture = upgrade_env()

    {out, code} =
      run_upgrade(fixture, "", "probe_control_liveness() { printf up; }")

    assert code == 64
    assert out =~ "aiur is running"
    assert out =~ "refuses to replace the binary under a live daemon"
    assert out =~ "aiur stop"
    # No npm install happened.
    assert File.read!(fixture.npm_log) == ""
  end

  test "upgrade --force proceeds under a running daemon, warning and reporting honestly" do
    fixture = upgrade_env(@live_dist_tags, "0.0.2")

    {out, 0} =
      run_upgrade(fixture, "--force", "probe_control_liveness() { printf up; }", "0.0.3")

    assert out =~ "aiur is running; --force upgrades anyway"
    assert out =~ "keeps the old"
    assert out =~ "until you restart it"
    assert out =~ "upgrading aiur-cli from 0.0.2 to 0.0.3"
    assert out =~ "aiur upgraded from 0.0.2 to 0.0.3"
    assert out =~ "Restart any running aiur"
    assert File.read!(fixture.npm_log) =~ "install -g aiur-cli@latest"
  end

  test "upgrade installs the newer version and reports before/after + restart note" do
    fixture = upgrade_env(@live_dist_tags, "0.0.2")

    {out, 0} = run_upgrade(fixture, "", "", "0.0.3")

    assert out =~ "upgrading aiur-cli from 0.0.2 to 0.0.3 on the latest channel"
    assert out =~ "aiur upgraded from 0.0.2 to 0.0.3"
    assert out =~ "Restart any running aiur to pick up the new version"
    assert File.read!(fixture.npm_log) =~ "install -g aiur-cli@latest"
    # The installed version is marked told, so the notice never re-offers it.
    assert File.read!(Path.join(fixture.state, "upgrade-notified.txt")) =~ "0.0.3"
  end

  test "upgrade is a no-op when already up to date (no npm install)" do
    fixture = upgrade_env(@live_dist_tags, "0.0.3")

    {out, 0} = run_upgrade(fixture)

    assert out =~ "already up to date on the latest channel (0.0.3)"
    assert File.read!(fixture.npm_log) == ""
  end

  test "a nightly user is never upgraded to `latest` when latest is lower (the live trap)" do
    # installed 0.0.5-nightly.x, latest=0.0.3: no upgrade, and no `latest` install.
    fixture = upgrade_env(@live_dist_tags, "0.0.5-nightly.9540a62")

    {out, 0} = run_upgrade(fixture)

    assert out =~ "already up to date on the nightly channel (0.0.5-nightly.9540a62)"
    assert File.read!(fixture.npm_log) == ""
  end

  test "a nightly user upgrades on the nightly channel when a newer nightly exists" do
    tags = ~s({"latest":"0.0.3","next":"0.0.4","nightly":"0.0.5-nightly.zzz"})
    fixture = upgrade_env(tags, "0.0.5-nightly.9540a62")

    {out, 0} = run_upgrade(fixture)

    assert out =~ "upgrading aiur-cli from 0.0.5-nightly.9540a62 to 0.0.5-nightly.zzz on the nightly channel"
    assert File.read!(fixture.npm_log) =~ "install -g aiur-cli@nightly"
  end

  test "a `next` user is measured against next, never downgraded to latest" do
    # installed 0.0.4 == next, latest=0.0.3: stays on next, no downgrade.
    fixture = upgrade_env(@live_dist_tags, "0.0.4")

    {out, 0} = run_upgrade(fixture)

    assert out =~ "already up to date on the next channel (0.0.4)"
    refute out =~ "latest channel"
    assert File.read!(fixture.npm_log) == ""
  end

  test "a `next` user upgrades on the next channel when a newer next exists" do
    tags = ~s({"latest":"0.0.3","next":"0.0.5","nightly":"0.0.5-nightly.x"})
    fixture = upgrade_env(tags, "0.0.4")

    {out, 0} = run_upgrade(fixture, "", "", "0.0.5")

    assert out =~ "upgrading aiur-cli from 0.0.4 to 0.0.5 on the next channel"
    assert File.read!(fixture.npm_log) =~ "install -g aiur-cli@next"
  end

  test "upgrade says plainly when the user's channel no longer publishes" do
    # nightly is gone
    tags = ~s({"latest":"0.0.3","next":"0.0.4"})
    fixture = upgrade_env(tags, "0.0.5-nightly.9540a62")

    {out, code} = run_upgrade(fixture)

    assert code == 64
    assert out =~ "the nightly channel no longer publishes new versions"
    assert out =~ "will not silently fall back to another channel"
    assert File.read!(fixture.npm_log) == ""
  end

  test "upgrade reports the registry unreachable rather than guessing" do
    fixture = upgrade_env()
    # Fake npm `view` exits nonzero → cmd_upgrade must abort, not install.
    File.write!(fixture.tags_file, "broken")
    npm_bin = Aiur.TestSupport.tmp_root!("aiur-fake-npm-down")
    File.mkdir_p!(npm_bin)
    down = Path.join(npm_bin, "npm")
    File.write!(down, "#!/usr/bin/env bash\nif [ \"${1:-}\" = \"view\" ]; then exit 1; fi\n# no install handler\n")
    File.chmod!(down, 0o755)
    on_exit(fn -> File.rm_rf!(npm_bin) end)

    script = """
    resolve_release() { :; }
    prepare_distribution() { :; }
    probe_control_liveness() { printf down; }
    aiur_install_method() { printf npm; }
    cli_package_version() { cat "$AIUR_VERSION_FILE"; }
    cmd_upgrade
    """

    {out, code} =
      run_sourced_engine(script, [
        {"AIUR_BG_STATE_DIR", fixture.state},
        {"AIUR_TAGS_FILE", fixture.tags_file},
        {"AIUR_VERSION_FILE", fixture.version_file},
        {"AIUR_NPM_LOG", fixture.npm_log},
        {"AIUR_UPGRADE_AFTER", "0.0.4"},
        {"PATH", "#{npm_bin}:/usr/bin:/bin"}
      ])

    assert code != 0
    assert out =~ "could not reach the npm registry"
    assert File.read!(fixture.npm_log) == ""
  end

  # --- the aiur run version notice surface (engine side) ---------------------

  # Write the daemon-owned state file the way Aiur.Upgrade.State.write/2 does.
  defp write_upgrade_state(fixture, notice_json) do
    state = Path.join(fixture.state, "upgrade.json")
    File.mkdir_p!(fixture.state)
    body = ~s({"last_check_ms":1,"dist_tags":{},"notice":#{notice_json}})
    File.write!(state, body)
    state
  end

  defp run_notice(script, fixture, extra_env \\ []) do
    run_sourced_engine(
      script,
      [
        {"AIUR_BG_STATE_DIR", fixture.state},
        {"AIUR_VERSION_FILE", fixture.version_file}
      ] ++ extra_env
    )
  end

  test "the notice surface prints a pending normal notice and marks it told" do
    fixture = upgrade_env()

    notice =
      ~s({"installed":"0.0.3","available":"0.0.4","channel":"latest","command":"aiur upgrade",) <>
        ~s("text":"aiur: a new version is available — 0.0.3 → 0.0.4. Update with: aiur upgrade","channel_gone":false})

    write_upgrade_state(fixture, notice)

    {out, 0} =
      run_notice(
        "cli_package_version() { cat \"$AIUR_VERSION_FILE\"; }\nmaybe_print_upgrade_notice",
        fixture
      )

    assert out =~ "a new version is available"
    assert out =~ "0.0.3 → 0.0.4"
    assert out =~ "aiur upgrade"
    # Marked told: a second run must stay silent.
    {out2, 0} =
      run_notice(
        "cli_package_version() { cat \"$AIUR_VERSION_FILE\"; }\nmaybe_print_upgrade_notice",
        fixture
      )

    assert out2 == ""
  end

  test "the notice surface prints a channel-gone notice once (boolean channel_gone)" do
    fixture = upgrade_env()

    notice =
      ~s({"installed":"0.0.5-nightly.9540a62","available":null,"channel":"nightly","command":null,) <>
        ~s|("text":"aiur: the nightly channel no longer publishes new versions (installed 0.0.5-nightly.9540a62). Run `aiur upgrade` to see what is available","channel_gone":true})|

    write_upgrade_state(fixture, notice)

    {out, 0} =
      run_notice(
        "cli_package_version() { cat \"$AIUR_VERSION_FILE\"; }\nmaybe_print_upgrade_notice",
        fixture
      )

    assert out =~ "nightly channel no longer publishes"
    assert out =~ "aiur upgrade"

    # Marked told; second run stays silent.
    {out2, 0} =
      run_notice(
        "cli_package_version() { cat \"$AIUR_VERSION_FILE\"; }\nmaybe_print_upgrade_notice",
        fixture
      )

    assert out2 == ""
  end

  test "the notice surface never offers a downgrade (ahead-of-latest nightly)" do
    fixture = upgrade_env(@live_dist_tags, "0.0.5-nightly.9540a62")

    notice =
      ~s({"installed":"0.0.5-nightly.9540a62","available":"0.0.3","channel":"latest",) <>
        ~s("text":"aiur: a new version is available — 0.0.5-nightly.9540a62 → 0.0.3. Update with: aiur upgrade","channel_gone":false})

    write_upgrade_state(fixture, notice)

    {out, 0} =
      run_notice(
        "cli_package_version() { cat \"$AIUR_VERSION_FILE\"; }\nmaybe_print_upgrade_notice",
        fixture
      )

    # A stale/wrong state file offering a downgrade must not be displayed.
    assert out == ""
  end

  test "the notice surface is silent under the aiurdev launcher and opt-outs" do
    fixture = upgrade_env()

    notice =
      ~s({"installed":"0.0.3","available":"0.0.4","channel":"latest","command":"aiur upgrade",) <>
        ~s("text":"aiur: a new version is available — 0.0.3 → 0.0.4. Update with: aiur upgrade","channel_gone":false})

    write_upgrade_state(fixture, notice)

    # Dev launcher release dir → silent even though a notice is pending.
    {dev_out, 0} =
      run_notice(
        "cli_package_version() { cat \"$AIUR_VERSION_FILE\"; }\nmaybe_surface_upgrade_notice",
        fixture,
        [{"AIUR_RELEASE_DIR", "/repo/src/_build/dev/rel/aiur"}]
      )

    assert dev_out == ""

    # Env opt-out → silent.
    {env_out, 0} =
      run_notice(
        "cli_package_version() { cat \"$AIUR_VERSION_FILE\"; }\nmaybe_surface_upgrade_notice",
        fixture,
        [{"AIUR_UPGRADE_CHECK_DISABLED", "1"}]
      )

    assert env_out == ""

    # Missing state file → silent.
    File.rm!(Path.join(fixture.state, "upgrade.json"))

    {missing_out, 0} =
      run_notice(
        "cli_package_version() { cat \"$AIUR_VERSION_FILE\"; }\nmaybe_surface_upgrade_notice",
        fixture
      )

    assert missing_out == ""
  end

  test "upgrade_state_string handles quoted and unquoted JSON scalars" do
    fixture = upgrade_env()
    file = Aiur.TestSupport.tmp_root!("aiur-json")
    File.write!(file, ~s({"latest":"0.0.3","channel_gone":true,"available":null}))
    on_exit(fn -> File.rm(file) end)

    {out, 0} =
      run_sourced_engine(
        """
        printf 'LATEST=%s\\n' "$(upgrade_state_string "#{file}" latest)"
        printf 'GONE=%s\\n' "$(upgrade_state_string "#{file}" channel_gone)"
        printf 'AVAIL=%s\\n' "$(upgrade_state_string "#{file}" available)"
        """,
        [{"AIUR_BG_STATE_DIR", fixture.state}]
      )

    assert out =~ "LATEST=0.0.3"
    assert out =~ "GONE=true"
    assert out =~ "AVAIL=null"
  end
end
