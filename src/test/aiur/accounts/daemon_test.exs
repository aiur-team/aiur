defmodule Aiur.AccountsDaemonTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Accounts
  alias Aiur.Accounts.UsageReadings
  alias Aiur.AccountsCLI

  setup do
    UsageReadings.reset()
    home = Aiur.TestSupport.tmp_root!("aiur-accounts")
    File.mkdir_p!(home)
    previous = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      UsageReadings.reset()
      if previous, do: System.put_env("HOME", previous), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "accounts json has no token-shaped values", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    File.write!(Path.join(home, ".claude.json"), ~s({"oauthAccount":{"emailAddress":"dev@example.com","organizationName":"Research","subscriptionType":"max"},"oauthToken":"sk-ant-oat01-secret"}))

    output = capture_io(fn -> assert :ok = Aiur.AccountsCLI.accounts(true) end)
    assert output =~ "weekly_percent"
    assert output =~ "dev@example.com"
    assert output =~ "Research"
    assert output =~ "max"
    assert output =~ "freshness"
    assert output =~ "observed_at"
    refute output =~ "sk-ant-oat01-secret"
    refute output =~ "oauthToken"
  end

  test "accounts keeps harness-generic listing and filters the requested backend" do
    :ok = Accounts.register("codex", "work", nil)

    output = capture_io(fn -> assert :ok = AccountsCLI.accounts(true, "codex") end)
    [json] = String.split(output, "\n", trim: true)
    rows = Jason.decode!(json)

    assert Enum.any?(rows, &(&1["name"] == "work" and &1["harness"] == "codex"))
    assert Enum.all?(rows, &(&1["harness"] == "codex"))
  end

  test "accounts json renders daemon snapshot percentages without requesting usage", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    File.write!(Path.join(home, ".claude.json"), ~s({"oauthAccount":{"emailAddress":"dev@example.com"}}))
    observed_at = DateTime.utc_now()

    snapshot_fun = fn ["default"] ->
      %{
        "default" => %{
          reading: %{
            windows: [
              %{window: "seven_day", used_percent: 41},
              %{window: "five_hour", used_percent: 18}
            ]
          },
          observed_at: observed_at,
          freshness: :cached
        }
      }
    end

    parent = self()

    output =
      capture_io(fn ->
        assert :ok =
                 Aiur.AccountsCLI.accounts(true, fn names ->
                   assert names == ["default"]
                   send(parent, {:snapshot_requested, names})
                   snapshot_fun.(names)
                 end)
      end)

    assert_received {:snapshot_requested, ["default"]}
    assert output =~ ~s("weekly_percent":41)
    assert output =~ ~s("five_hour_percent":18)
    assert output =~ ~s("freshness":"cached")
    assert output =~ DateTime.to_iso8601(observed_at)
    assert output =~ ~s("age_ms":)
  end

  test "daemon accounts control command reads the polled usage snapshot", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    File.write!(Path.join(home, ".claude.json"), ~s({"oauthAccount":{"emailAddress":"dev@example.com"}}))
    :ok = Accounts.register("claude", "max", nil)

    UsageReadings.record(
      "claude",
      "max",
      {:ok,
       %{
         windows: [
           %{window: "seven_day", used_percent: 41},
           %{window: "five_hour", used_percent: 18}
         ]
       }},
      DateTime.utc_now()
    )

    output = capture_io(fn -> Aiur.AgentControlCLI.accounts(true) end)
    [json | _marker] = String.split(output, "\n", trim: true)
    row = Enum.find(Jason.decode!(json), &(&1["name"] == "max"))

    assert row["weekly_percent"] == 41
    assert row["five_hour_percent"] == 18
    assert row["freshness"] == "fresh"
    assert row["observed_at"]
    assert is_integer(row["age_ms"])
  end

  test "accounts json reports daemon not running while retaining identity", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    File.write!(Path.join(home, ".claude.json"), ~s({"oauthAccount":{"emailAddress":"dev@example.com"}}))

    output = capture_io(fn -> assert :ok = Aiur.AccountsCLI.accounts(true) end)
    assert output =~ "dev@example.com"
    assert output =~ ~s("freshness":"daemon_not_running")
    assert output =~ ~s("weekly_percent":null)
  end

  test "accounts json preserves the daemon usage error reason", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    File.write!(Path.join(home, ".claude.json"), ~s({"oauthAccount":{"emailAddress":"dev@example.com"}}))
    observed_at = DateTime.utc_now()

    output =
      capture_io(fn ->
        Aiur.AccountsCLI.accounts(true, fn _names ->
          %{"default" => %{reading: nil, observed_at: observed_at, freshness: :unavailable, reason: :no_oauth_token}}
        end)
      end)

    assert output =~ ~s("freshness":"no_oauth_token")
  end

  test "usage readings are isolated by harness and account" do
    observed_at = DateTime.utc_now()
    UsageReadings.record("claude", "default", {:error, :no_oauth_token}, observed_at)
    UsageReadings.record("other", "default", {:ok, %{windows: []}}, observed_at)

    assert %{"default" => %{freshness: :unavailable, reason: :no_oauth_token}} =
             UsageReadings.snapshot("claude", ["default"])
  end
end
