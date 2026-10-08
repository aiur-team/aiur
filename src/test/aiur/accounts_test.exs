defmodule Aiur.AccountsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.Accounts
  alias Aiur.Accounts.Shims.Claude
  alias Aiur.Accounts.UsageReadings
  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.Issue

  setup do
    UsageReadings.reset()
    home = Path.join(System.tmp_dir!(), "aiur-accounts-#{System.unique_integer([:positive])}")
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

    UsageReadings.record(
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
    UsageReadings.record("claude", "default", {:error, :no_oauth_token}, observed_at)
    UsageReadings.record("other", "default", {:ok, %{windows: []}}, observed_at)

    assert %{"default" => %{freshness: :unavailable, reason: :no_oauth_token}} =
             UsageReadings.snapshot("claude", ["default"])
  end

  test "moves Claude session artifacts and merges only that session history by timestamp", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join(home, ".claude")
    destination = Path.join([home, ".aiur/accounts/claude/work"])
    session = "11111111-2222-4333-8444-555555555555"
    project = Aiur.Claude.RemoteControl.workspace_slug("/repo")
    transcript = Path.join([source, "projects", project, session <> ".jsonl"])
    File.mkdir_p!(Path.dirname(transcript))
    File.write!(transcript, "transcript")

    File.write!(
      Path.join(source, "history.jsonl"),
      Enum.join(
        [
          Jason.encode!(%{"sessionId" => session, "timestamp" => "2026-01-02T00:00:00Z"}),
          Jason.encode!(%{"sessionId" => "other", "timestamp" => "2026-01-01T00:00:00Z"})
        ],
        "\n"
      ) <> "\n"
    )

    File.write!(Path.join(destination, "history.jsonl"), Jason.encode!(%{"sessionId" => "existing", "timestamp" => "2026-01-01T12:00:00Z"}) <> "\n")

    assert :ok = Accounts.move_session("claude", "default", "work", session, "/repo")
    refute File.exists?(transcript)
    assert File.read!(Path.join([destination, "projects", project, session <> ".jsonl"])) == "transcript"
    history = File.read!(Path.join(destination, "history.jsonl")) |> String.split("\n", trim: true)
    assert Enum.map(history, &Jason.decode!/1) |> Enum.map(& &1["sessionId"]) == ["existing", session]
    assert File.read!(Path.join(source, "history.jsonl")) =~ "other"
    refute File.read!(Path.join(source, "history.jsonl")) =~ session
  end

  test "moves a session into the default profile", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join([home, ".aiur/accounts/claude/work"])
    session = "11111111-2222-4333-8444-555555555555"
    transcript = Path.join([source, "projects", Aiur.Claude.RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])
    File.mkdir_p!(Path.dirname(transcript))
    File.write!(transcript, "transcript")

    assert :ok = Accounts.move_session("claude", "work", "default", session, "/repo")
    refute File.exists?(transcript)
    assert File.read!(Path.join([home, ".claude", "projects", Aiur.Claude.RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])) == "transcript"
  end

  test "skips a destination artifact symlink that resolves to the source file", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join(home, ".claude")
    destination = Path.join([home, ".aiur/accounts/claude/work"])
    session = "11111111-2222-4333-8444-555555555555"
    relative = Path.join(["projects", Aiur.Claude.RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])
    source_transcript = Path.join(source, relative)
    destination_transcript = Path.join(destination, relative)
    File.mkdir_p!(Path.dirname(source_transcript))
    File.mkdir_p!(Path.dirname(destination_transcript))
    File.write!(source_transcript, "transcript")
    File.ln_s!(source_transcript, destination_transcript)

    assert :ok = Accounts.move_session("claude", "default", "work", session, "/repo")
    assert File.read!(source_transcript) == "transcript"
    assert File.read!(destination_transcript) == "transcript"
    assert File.read_link!(destination_transcript) == source_transcript
  end

  test "reports source deletion failure after a verified cross-filesystem copy", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join(home, ".claude")
    session = "11111111-2222-4333-8444-555555555555"
    transcript = Path.join([source, "projects", Aiur.Claude.RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])
    File.mkdir_p!(Path.dirname(transcript))
    File.write!(transcript, "transcript")
    rm = fn path -> if path == transcript, do: {:error, :injected_delete_failure}, else: File.rm_rf(path) end

    assert {:error, {:source_delete_failed, :injected_delete_failure}} =
             Accounts.move_session("claude", "default", "work", session, "/repo", same_device: false, rm_rf: rm)

    assert File.read!(transcript) == "transcript"
    refute File.exists?(Path.join([home, ".aiur/accounts/claude/work", "projects", Aiur.Claude.RemoteControl.workspace_slug("/repo"), session <> ".jsonl"]))
  end

  test "refuses a live session and a destination that already contains it", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join(home, ".claude")
    destination = Path.join([home, ".aiur/accounts/claude/work"])
    session = "11111111-2222-4333-8444-555555555555"
    registry = Path.join(source, "sessions")
    File.mkdir_p!(registry)
    File.write!(Path.join(registry, session <> ".json"), "{}")
    assert {:error, :session_live} = Accounts.move_session("claude", "default", "work", session, "/repo")
    File.rm!(Path.join(registry, session <> ".json"))
    destination_artifact = Path.join([destination, "projects", Aiur.Claude.RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])
    File.mkdir_p!(Path.dirname(destination_artifact))
    File.write!(destination_artifact, "pre-existing")
    assert {:error, :destination_session_exists} = Accounts.move_session("claude", "default", "work", session, "/repo")
  end

  test "rolls back earlier artifact renames when a later rename fails", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join(home, ".claude")
    destination = Path.join([home, ".aiur/accounts/claude/work"])
    session = "11111111-2222-4333-8444-555555555555"
    project = Path.join([source, "projects", Aiur.Claude.RemoteControl.workspace_slug("/repo")])
    File.mkdir_p!(project)
    transcript = Path.join(project, session <> ".jsonl")
    File.write!(transcript, "source")
    file_history = Path.join([source, "file-history", session])
    File.mkdir_p!(file_history)
    File.write!(Path.join(file_history, "snapshot"), "history")
    conflict = Path.join([destination, "projects", Aiur.Claude.RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])

    rename = fn from, to ->
      if String.ends_with?(from, session <> ".jsonl"), do: {:error, :injected_failure}, else: File.rename(from, to)
    end

    assert {:error, :injected_failure} = Accounts.move_session("claude", "default", "work", session, "/repo", rename: rename)
    assert File.read!(transcript) == "source"
    assert File.read!(Path.join(file_history, "snapshot")) == "history"
    refute File.exists?(conflict)
  end

  test "copies and verifies the session artifacts before removing the source on another filesystem", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join(home, ".claude")
    destination = Path.join([home, ".aiur/accounts/claude/work"])
    session = "11111111-2222-4333-8444-555555555555"
    project = Path.join([source, "projects", Aiur.Claude.RemoteControl.workspace_slug("/repo")])
    File.mkdir_p!(project)
    transcript = Path.join(project, session <> ".jsonl")
    File.write!(transcript, "verified transcript")
    parent = self()

    copy = fn from, to ->
      send(parent, {:copied, from, to})
      File.cp_r(from, to)
    end

    assert :ok = Accounts.move_session("claude", "default", "work", session, "/repo", same_device: false, copy: copy)
    assert_received {:copied, ^transcript, _}
    refute File.exists?(transcript)
    assert File.read!(Path.join([destination, "projects", Aiur.Claude.RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])) == "verified transcript"
  end
end
