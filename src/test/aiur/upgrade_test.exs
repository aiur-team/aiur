defmodule Aiur.Upgrade.VersionTest do
  use ExUnit.Case, async: true

  alias Aiur.Upgrade.Version

  # The live registry shape: latest=0.0.3, next=0.0.4, nightly=0.0.5-nightly.<sha>.
  # Prerelease ordering must hold exactly — 0.0.5-nightly.x is OLDER than 0.0.5
  # but NEWER than 0.0.3. This is the case live today, so it is asserted
  # directly (issue #2109).
  describe "semver prerelease ordering (the live case)" do
    test "0.0.5-nightly.x is older than 0.0.5" do
      assert Version.compare("0.0.5-nightly.cd08c27", "0.0.5") == :lt
      refute Version.newer?("0.0.5-nightly.cd08c27", "0.0.5")
    end

    test "0.0.5-nightly.x is newer than 0.0.3" do
      assert Version.compare("0.0.5-nightly.cd08c27", "0.0.3") == :gt
      assert Version.newer?("0.0.5-nightly.cd08c27", "0.0.3")
    end

    test "0.0.5 is newer than 0.0.3" do
      assert Version.newer?("0.0.5", "0.0.3")
    end

    test "nightly prerelease identifiers compare within the channel" do
      assert Version.newer?("0.0.5-nightly.b", "0.0.5-nightly.a")
      assert Version.compare("0.0.5-nightly.a", "0.0.5-nightly.b") == :lt
      # Numeric identifiers sort numerically, not lexically.
      assert Version.compare("0.0.5-nightly.2", "0.0.5-nightly.10") == :lt
    end
  end

  describe "plain semver" do
    test "compares numerically, not lexically" do
      assert Version.newer?("1.2.10", "1.2.3")
    end

    test "release outranks a same-core prerelease" do
      assert Version.newer?("1.0.0", "1.0.0-rc.1")
      refute Version.newer?("1.0.0-rc.1", "1.0.0")
    end

    test "equality" do
      assert Version.compare("0.0.3", "0.0.3") == :eq
    end
  end

  describe "hostile input" do
    test "rejects trailing junk / control bytes" do
      assert Version.parse("999.0.0 \e[2Jpwned") == :error
      assert Version.parse("999.0.0  pwned") == :error
      assert Version.parse(nil) == :error
      assert Version.parse(123) == :error
      assert Version.newer?("999.0.0 \e[2Jpwned", "0.0.1") == false
    end

    test "accepts a +build suffix but ignores it for ordering" do
      assert Version.parse("1.2.10+build.5") == {:ok, %{major: 1, minor: 2, patch: 10, pre: []}}
      assert Version.newer?("1.2.10+build.5", "1.2.3")
    end
  end
end

defmodule Aiur.UpgradeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.Upgrade
  alias Aiur.Upgrade.Notice
  alias Aiur.Upgrade.State

  # Real published registry values, per the operator's corrected measurement.
  @live_tags %{
    "latest" => "0.0.3",
    "next" => "0.0.4",
    "nightly" => "0.0.5-nightly.cd08c27"
  }

  # A counting, canned transport so tests assert outbound call counts without
  # any network.
  defmodule CountingTransport do
    @behaviour Aiur.Upgrade.Registry.Transport

    def start(response) do
      {:ok, pid} = Agent.start_link(fn -> %{response: response, count: 0} end)
      Process.put({__MODULE__, :pid}, pid)
      pid
    end

    def count, do: Agent.get(Process.get({__MODULE__, :pid}), & &1.count)
    def set(response), do: Agent.update(Process.get({__MODULE__, :pid}), &%{&1 | response: response})

    @impl true
    def fetch_dist_tags(_url, _timeout_ms) do
      Agent.get_and_update(Process.get({__MODULE__, :pid}), fn state ->
        {state.response, %{state | count: state.count + 1}}
      end)
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "aiur-upgrade-test-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    state_file = Path.join(tmp, "upgrade.json")
    Process.put(:upgrade_test_state_file, state_file)
    on_exit(fn -> File.rm_rf!(tmp) end)

    previous_env = %{
      "AIUR_UPGRADE_CHECK_DISABLED" => System.get_env("AIUR_UPGRADE_CHECK_DISABLED"),
      "AIUR_NO_UPDATE_NOTIFIER" => System.get_env("AIUR_NO_UPDATE_NOTIFIER"),
      "AIUR_RELEASE_DIR" => System.get_env("AIUR_RELEASE_DIR"),
      "CI" => System.get_env("CI"),
      "AIUR_CLI_VERSION" => System.get_env("AIUR_CLI_VERSION")
    }

    for key <- Map.keys(previous_env), do: System.delete_env(key)

    on_exit(fn ->
      for {key, value} <- previous_env do
        if is_nil(value), do: System.delete_env(key), else: System.put_env(key, value)
      end
    end)

    :ok
  end

  defp state_file, do: Process.get(:upgrade_test_state_file)
  defp notified_file, do: Path.join(Path.dirname(state_file()), "upgrade-notified.txt")

  defp run_check(opts) do
    opts =
      opts
      |> Keyword.put_new(:state_file, state_file())
      |> Keyword.put_new(:settings, {:ok, %{upgrade: %{check_enabled: true}}})

    Upgrade.check_and_announce(opts)
  end

  defp fresh_state(overrides) do
    state =
      Map.merge(
        %{
          "last_check_ms" => System.os_time(:millisecond),
          "dist_tags" => @live_tags,
          "notice" => nil
        },
        overrides
      )

    file = state_file()
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Jason.encode!(state))
  end

  describe "channel resolution (all three live channels)" do
    test "resolves latest, next and nightly from installed version + dist-tags" do
      assert Upgrade.channel("0.0.3", @live_tags) == :latest
      assert Upgrade.channel("0.0.4", @live_tags) == :next
      assert Upgrade.channel("0.0.5-nightly.cd08c27", @live_tags) == :nightly
    end
  end

  describe "notice message content" do
    test "a newer version on the user's channel yields a notice naming installed, available and command" do
      notice = Upgrade.notice("0.0.3", %{"latest" => "0.0.4"})
      assert %Notice{installed: "0.0.3", available: "0.0.4", channel: :latest, command: "aiur upgrade"} = notice
      assert notice.text =~ "0.0.3"
      assert notice.text =~ "0.0.4"
      assert notice.text =~ "aiur upgrade"
    end

    test "with no newer version nothing is shown" do
      assert Upgrade.notice("0.0.3", @live_tags) == :none
      assert Upgrade.notice("0.0.4", @live_tags) == :none
      assert Upgrade.notice("0.0.5-nightly.cd08c27", @live_tags) == :none
    end
  end

  describe "the downgrade trap (issue #2109)" do
    test "a nightly user is never offered `latest` when `latest` is lower (the live case)" do
      # installed 0.0.5-nightly.x, latest 0.0.3 — no upgrade may be offered.
      assert Upgrade.notice("0.0.5-nightly.cd08c27", @live_tags) == :none
    end

    test "a `next` user at 0.0.4 is not told to move to `latest` at 0.0.3" do
      assert Upgrade.notice("0.0.4", @live_tags) == :none
    end

    test "a newer nightly within the nightly channel is offered, never `latest`" do
      tags = %{"latest" => "0.0.3", "nightly" => "0.0.5-nightly.zzz"}
      assert %Notice{available: "0.0.5-nightly.zzz", channel: :nightly} = Upgrade.notice("0.0.5-nightly.cd08c27", tags)
    end

    test "a newer version in the user's channel is offered even when `latest` is lower" do
      tags = %{"latest" => "0.0.3", "next" => "0.0.5"}
      assert %Notice{available: "0.0.5", channel: :next} = Upgrade.notice("0.0.4", tags)
    end
  end

  describe "a channel that no longer publishes" do
    test "says so plainly instead of comparing against the wrong channel" do
      assert %Notice{available: nil, channel: :nightly, channel_gone: true, command: nil} =
               Upgrade.notice("0.0.5-nightly.cd08c27", %{"latest" => "0.0.3"})

      notice = Upgrade.notice("0.0.5-nightly.cd08c27", %{"latest" => "0.0.3"})
      assert notice.text =~ "nightly channel no longer publishes"
      assert notice.text =~ "0.0.5-nightly.cd08c27"
    end

    test "does not repeat the channel-gone notice once told" do
      assert Upgrade.notice("0.0.5-nightly.cd08c27", %{"latest" => "0.0.3"}, "gone:nightly") == :none
    end

    test "offers a strictly-newer latest as a migration path when the channel is gone" do
      # 0.0.6 is genuinely newer than 0.0.5-nightly.x, so migration is offered.
      tags = %{"latest" => "0.0.6"}

      assert %Notice{available: "0.0.6", channel: :latest, command: "aiur upgrade", channel_gone: true} =
               Upgrade.notice("0.0.5-nightly.cd08c27", tags)
    end
  end

  describe "do not repeat yourself" do
    test "the same version is not announced twice" do
      assert Upgrade.notice("0.0.3", %{"latest" => "0.0.4"}, "0.0.4") == :none
      assert Upgrade.notice("0.0.3", %{"latest" => "0.0.4"}, "0.0.5") == :none
    end

    test "a newer version after the notified one is announced again" do
      assert %Notice{available: "0.0.5"} = Upgrade.notice("0.0.3", %{"latest" => "0.0.5"}, "0.0.4")
    end

    test "a stored notice is not re-logged once the engine marked it as told" do
      CountingTransport.start({:ok, %{"latest" => "0.0.5"}})

      fresh_state(%{
        "notice" => %{
          "installed" => "0.0.3",
          "available" => "0.0.4",
          "channel" => "latest",
          "command" => "aiur upgrade",
          "text" => "aiur: a new version is available — 0.0.3 → 0.0.4. Update with: aiur upgrade",
          "channel_gone" => false
        }
      })

      # The engine's surface path wrote the marker after displaying once.
      State.write_notified("0.0.4", notified_file())

      log = capture_log(fn -> assert :ok = run_check(transport: CountingTransport) end)

      assert CountingTransport.count() == 0
      refute log =~ "aiur_upgrade"
    end
  end

  describe "registry unreachable fails open" do
    test "the run proceeds and prints no version notice" do
      CountingTransport.start({:error, :econnrefused})

      log =
        capture_log(fn ->
          assert :ok = run_check(transport: CountingTransport)
        end)

      assert CountingTransport.count() == 1
      refute log =~ "aiur_upgrade"
      # The state is stamped so an offline host does not retry every run, and no
      # notice is recorded.
      assert {:ok, state} = Upgrade.State.read(state_file())
      assert state.notice == nil
    end
  end

  describe "cache with a TTL" do
    test "a fresh cache surfaces the pending notice without hitting the network" do
      CountingTransport.start({:ok, %{"latest" => "0.0.5"}})

      # A prior check already computed and stored this notice.
      fresh_state(%{
        "notice" => %{
          "installed" => "0.0.3",
          "available" => "0.0.4",
          "channel" => "latest",
          "command" => "aiur upgrade",
          "text" => "aiur: a new version is available — 0.0.3 → 0.0.4\n      update: aiur upgrade",
          "channel_gone" => false
        }
      })

      log =
        capture_log(fn ->
          assert :ok = run_check(transport: CountingTransport)
        end)

      assert CountingTransport.count() == 0
      # The pending notice from the cached state is surfaced, no network.
      assert log =~ "a new version is available"
    end

    test "a stale cache is refreshed once, then subsequent runs stay offline" do
      CountingTransport.start({:ok, %{"latest" => "0.0.4"}})
      fresh_state(%{"last_check_ms" => 0})

      capture_log(fn ->
        assert :ok = run_check(transport: CountingTransport)
        assert :ok = run_check(transport: CountingTransport)
      end)

      # One fetch for the stale cache; the second run sees the fresh stamp.
      assert CountingTransport.count() == 1
    end
  end

  describe "disable via config and via environment variable" do
    test "AIUR_UPGRADE_CHECK_DISABLED suppresses the check entirely (zero outbound)" do
      System.put_env("AIUR_UPGRADE_CHECK_DISABLED", "1")
      CountingTransport.start({:ok, %{"latest" => "0.0.4"}})
      fresh_state(%{"last_check_ms" => 0})
      File.rm!(state_file())

      log =
        capture_log(fn ->
          assert :ok = run_check(transport: CountingTransport)
        end)

      assert CountingTransport.count() == 0
      refute log =~ "aiur_upgrade"
      # A disabled check never creates the state file.
      refute File.exists?(state_file())
    end

    test "the legacy AIUR_NO_UPDATE_NOTIFIER env var also suppresses the check" do
      System.put_env("AIUR_NO_UPDATE_NOTIFIER", "1")
      CountingTransport.start({:ok, %{"latest" => "0.0.4"}})
      fresh_state(%{"last_check_ms" => 0})

      capture_log(fn -> assert :ok = run_check(transport: CountingTransport) end)

      assert CountingTransport.count() == 0
    end

    test "upgrade.check_enabled: false in config suppresses the check entirely (zero outbound)" do
      CountingTransport.start({:ok, %{"latest" => "0.0.4"}})
      fresh_state(%{"last_check_ms" => 0})
      disabled_settings = {:ok, %{upgrade: %{check_enabled: false}}}

      capture_log(fn ->
        assert :ok = Upgrade.check_and_announce(transport: CountingTransport, state_file: state_file(), settings: disabled_settings)
      end)

      assert CountingTransport.count() == 0
    end

    test "CI suppresses the check" do
      System.put_env("CI", "true")
      CountingTransport.start({:ok, %{"latest" => "0.0.4"}})
      fresh_state(%{"last_check_ms" => 0})

      capture_log(fn -> assert :ok = run_check(transport: CountingTransport) end)

      assert CountingTransport.count() == 0
    end
  end

  describe "no notice under a development launcher" do
    test "aiurdev (AIUR_RELEASE_DIR points at a dev build) stays silent even when installed is behind" do
      # Local version BEHIND the published one: a dev launcher must still stay silent.
      System.put_env("AIUR_RELEASE_DIR", "/home/dev/src/_build/dev/rel/aiur")
      System.put_env("AIUR_CLI_VERSION", "0.0.2")
      CountingTransport.start({:ok, %{"latest" => "0.0.4"}})
      fresh_state(%{"last_check_ms" => 0})

      log =
        capture_log(fn ->
          assert :ok = run_check(transport: CountingTransport)
        end)

      assert CountingTransport.count() == 0
      refute log =~ "aiur_upgrade"
    end

    test "aiurdev stays silent when the local version is ahead of published" do
      System.put_env("AIUR_RELEASE_DIR", "/home/dev/src/_build/dev/rel/aiur")
      System.put_env("AIUR_CLI_VERSION", "0.0.5")
      CountingTransport.start({:ok, %{"latest" => "0.0.3"}})
      fresh_state(%{"last_check_ms" => 0})

      capture_log(fn -> assert :ok = run_check(transport: CountingTransport) end)

      assert CountingTransport.count() == 0
    end

    test "an installed aiur run from inside a clone (non-dev release dir) still checks" do
      System.put_env("AIUR_RELEASE_DIR", "/usr/local/lib/node_modules/aiur-cli-linux-x64/release")
      System.put_env("AIUR_CLI_VERSION", "0.0.3")
      CountingTransport.start({:ok, %{"latest" => "0.0.4"}})
      fresh_state(%{"last_check_ms" => 0})

      log =
        capture_log(fn ->
          assert :ok = run_check(transport: CountingTransport)
        end)

      assert CountingTransport.count() == 1
      assert log =~ "a new version is available"
    end
  end

  describe "check_and_announce integration" do
    test "writes the computed notice to state and logs it" do
      CountingTransport.start({:ok, %{"latest" => "0.0.4"}})
      System.put_env("AIUR_CLI_VERSION", "0.0.3")

      log =
        capture_log(fn ->
          assert :ok = run_check(transport: CountingTransport)
        end)

      assert log =~ "aiur_upgrade aiur: a new version is available — 0.0.3 → 0.0.4"
      assert {:ok, state} = Upgrade.State.read(state_file())
      assert state.notice["text"] =~ "aiur upgrade"
      assert state.dist_tags["latest"] == "0.0.4"
      assert is_integer(state.last_check_ms)
    end

    test "installed version falls back to the mix version when the launcher did not set it" do
      # AIUR_CLI_VERSION is unset in setup; mix.exs is 0.0.5.
      assert Upgrade.installed_version() == "0.0.5"
    end
  end
end
