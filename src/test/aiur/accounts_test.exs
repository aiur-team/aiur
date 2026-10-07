defmodule Aiur.AccountsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.Accounts
  alias Aiur.Accounts.Shims.Claude
  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.Issue

  setup do
    Aiur.Accounts.UsageReadings.reset()
    home = Path.join(System.tmp_dir!(), "aiur-accounts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      Aiur.Accounts.UsageReadings.reset()
      if previous, do: System.put_env("HOME", previous), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    %{home: home}
  end

  test "priority and balance selection skip limits and rank unknown usage last", %{home: home} do
    :ok = Accounts.register("claude", "low", nil)
    :ok = Accounts.register("claude", "high", nil)
    :ok = Accounts.register("claude", "unknown", nil)

    usage = %{
      "low" => %{"seven_day" => 25, "five_hour" => 90},
      "high" => %{"seven_day" => 70, "five_hour" => 10},
      "unknown" => nil
    }

    assert {:ok, "high"} = Accounts.select("claude", ["high", "low"], "priority", usage)
    assert {:ok, "high"} = Accounts.select("claude", ["unknown", "high"], "priority", usage)
    assert {:ok, "low"} = Accounts.select("claude", ["high", "low"], "balance", usage)

    tied_usage = %{
      "low" => %{"seven_day" => 25, "five_hour" => 15},
      "high" => %{"seven_day" => 25, "five_hour" => 10}
    }

    assert {:ok, "high"} = Accounts.select("claude", ["low", "high"], "balance", tied_usage)

    five_hour_limited = %{
      "five-hour-limited" => %{"seven_day" => 10, "five_hour" => 100},
      "available" => %{"seven_day" => 40, "five_hour" => 20}
    }

    assert {:ok, "available"} = Accounts.select("claude", ["five-hour-limited", "available"], "priority", five_hour_limited)
    assert {:ok, "available"} = Accounts.select("claude", ["five-hour-limited", "available"], "balance", five_hour_limited)

    usage = put_in(usage["low"]["seven_day"], 100)
    assert {:ok, "high"} = Accounts.select("claude", ["low", "high"], "priority", usage)
    assert {:ok, "high"} = Accounts.select("claude", ["low", "high", "unknown"], "balance", usage)
    assert {:ok, "unknown"} = Accounts.select("claude", ["low", "unknown"], "priority", usage)

    assert {:error, :no_available_account} =
             Accounts.select("claude", ["low"], "priority", %{"low" => %{"seven_day" => 100, "five_hour" => 100}})

    assert Path.join([home, ".aiur/accounts/claude/low"]) ==
             Accounts.list("claude") |> Enum.find(&(&1.name == "low")) |> Map.fetch!(:profile_dir)

    # Selection depends only on its arguments; the profile registry is a caller concern.
    assert {:ok, "candidate"} = Accounts.select("other-harness", ["candidate"], "priority", %{})
  end

  test "Claude profile env preserves the exact path and default has no override", %{home: home} do
    dir = Path.join(home, "profiles/max")
    assert [{"CLAUDE_CONFIG_DIR", ^dir}] = Claude.profile_env(dir)
    assert Accounts.profile_env("claude", "default") == []
  end

  test "Claude dispatch pins the selected non-default profile in adapter session options", %{home: home} do
    :ok = Accounts.register("claude", "max", nil)
    :ok = Accounts.register("claude", "max", nil)
    issue = %Issue{id: "account-dispatch", identifier: "ACCT", selected_backend: "claude"}

    {"claude", false, session_opts} =
      SessionLifecycle.resolve_session_options(
        issue,
        [
          account_config: %{accounts: %{"claude" => ["max"]}, account_selection: "priority"},
          account_usage_fetcher: fn _name -> %{"seven_day" => 10, "five_hour" => 20} end
        ],
        nil
      )

    assert Keyword.fetch!(session_opts, :account_name) == "max"
    assert Keyword.fetch!(session_opts, :env) == [{"CLAUDE_CONFIG_DIR", Path.join([home, ".aiur/accounts/claude/max"])}]

    remote_issue = %{issue | labels: ["model:remote"]}

    {"claude-repl", true, remote_opts} =
      SessionLifecycle.resolve_session_options(
        remote_issue,
        [
          account_config: %{accounts: %{"claude" => ["max"]}, account_selection: "priority"},
          account_usage_fetcher: fn _name -> %{"seven_day" => 10, "five_hour" => 20} end
        ],
        nil
      )

    assert Keyword.fetch!(remote_opts, :env) == Keyword.fetch!(session_opts, :env)

    parent = self()

    assert {:ok, %{backend: "claude"}} =
             SessionLifecycle.start_agent_session("/workspace", session_opts, fn _workspace, opts ->
               send(parent, {:adapter_opts, opts})
               {:ok, %{account_name: Keyword.get(opts, :account_name)}}
             end)

    assert_receive {:adapter_opts, adapter_opts}, 1000
    assert Keyword.fetch!(adapter_opts, :env) == Keyword.fetch!(session_opts, :env)
  end

  test "dispatch reuses the latest polled reading instead of issuing another usage request", %{home: home} do
    :ok = Accounts.register("claude", "max", nil)

    Aiur.Accounts.UsageReadings.record(
      "claude",
      "max",
      {:ok,
       %{
         windows: [
           %{window: "seven_day", used_percent: 37},
           %{window: "five_hour", used_percent: 22}
         ]
       }},
      DateTime.utc_now()
    )

    issue = %Issue{id: "account-polled", identifier: "ACCT-POLL", selected_backend: "claude"}

    {"claude", false, session_opts} =
      SessionLifecycle.resolve_session_options(
        issue,
        [
          account_config: %{accounts: %{"claude" => ["max"]}, account_selection: "balance"},
          account_usage_fetcher: fn _name -> flunk("dispatch should reuse the polled usage reading") end
        ],
        nil
      )

    assert Keyword.fetch!(session_opts, :account_name) == "max"
    assert Keyword.fetch!(session_opts, :account_selection_reason) == nil
    assert Keyword.fetch!(session_opts, :env) == [{"CLAUDE_CONFIG_DIR", Path.join([home, ".aiur/accounts/claude/max"])}]
  end

  test "profile setup links shared files and memory but never account transcripts or secrets", %{home: home} do
    source = Path.join(home, ".claude")
    File.mkdir_p!(Path.join(source, "projects/demo/memory"))
    File.mkdir_p!(Path.join(source, "projects/demo/transcripts"))
    File.write!(Path.join(source, "settings.json"), "{}")
    File.write!(Path.join(source, "CLAUDE.md"), "shared")
    File.write!(Path.join(source, ".claude.json"), ~s({"token":"secret"}))
    File.write!(Path.join(source, "projects/demo/memory/MEMORY.md"), "memory")
    File.write!(Path.join(source, "projects/demo/transcripts/session.jsonl"), "private")

    :ok = Accounts.register("claude", "max", nil)
    target = Path.join([home, ".aiur/accounts/claude/max"])
    assert File.read_link!(Path.join(target, "settings.json")) == Path.join(source, "settings.json")
    assert File.read_link!(Path.join(target, "projects/demo/memory")) == Path.join(source, "projects/demo/memory")
    refute File.exists?(Path.join(target, ".claude.json"))
    refute File.exists?(Path.join(target, "projects/demo/transcripts"))
  end

  test "adoption requires an existing directory and logout protects default unless purging a named profile", %{home: home} do
    existing = Path.join(home, "existing-profile")
    File.mkdir_p!(existing)
    assert :ok = Accounts.register("claude", "adopted", existing)
    assert {:error, :trailing_slash_in_dir} = Aiur.AccountsCLI.login("other", existing <> "/")
    assert {:error, :default_profile_already_reserved} = Accounts.register("claude", "alias", Path.join(home, ".claude"))

    assert {:error, :default_account_protected} = Accounts.logout("default", true)
    assert :ok = Accounts.logout("adopted", false)
    assert File.dir?(existing)

    assert :ok = Accounts.register("claude", "purged", nil)
    profile = Path.join([home, ".aiur/accounts/claude/purged"])
    assert :ok = Accounts.logout("purged", true)
    refute File.exists?(profile)
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

  test "usage readings are isolated by harness and account" do
    observed_at = DateTime.utc_now()
    Aiur.Accounts.UsageReadings.record("claude", "default", {:error, :no_oauth_token}, observed_at)
    Aiur.Accounts.UsageReadings.record("other", "default", {:ok, %{windows: []}}, observed_at)

    assert %{"default" => %{freshness: :unavailable, reason: :no_oauth_token}} =
             Aiur.Accounts.UsageReadings.snapshot("claude", ["default"])
  end
end
