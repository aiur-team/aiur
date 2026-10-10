defmodule Aiur.AccountsTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.Accounts
  alias Aiur.Accounts.Shims.Claude
  alias Aiur.Accounts.Shims.Codex, as: CodexAccounts
  alias Aiur.Accounts.UsageReadings
  alias Aiur.AccountsCLI
  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.Claude.RemoteControl
  alias Aiur.CodingAgent
  alias Aiur.Issue
  alias Aiur.OpenAICompat.Config, as: OpenAIConfig

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
    assert Accounts.profile_env("claude", "default") == [{"CLAUDE_CONFIG_DIR", false}]
  end

  test "Codex profile copies only shared config and skills and reads identity metadata", %{home: home} do
    source = Path.join(home, ".codex")
    File.mkdir_p!(Path.join(source, "skills"))
    File.write!(Path.join(source, "config.toml"), "model = 'test'")

    File.write!(
      Path.join(source, "auth.json"),
      Jason.encode!(%{
        "tokens" => %{
          "id_token" => "header.#{Base.url_encode64(Jason.encode!(%{"email" => "codex@example.com", "chatgpt_account_id" => "acct-123"}), padding: false)}.signature",
          "access_token" => "secret-token"
        },
        "account_id" => "acct-123"
      })
    )

    :ok = Accounts.register("codex", "work", nil)
    profile = Path.join([home, ".aiur/accounts/codex/work"])
    assert [{"CODEX_HOME", ^profile}] = Accounts.profile_env("codex", "work")
    assert File.read_link!(Path.join(profile, "config.toml")) == Path.join(source, "config.toml")
    assert File.read_link!(Path.join(profile, "skills")) == Path.join(source, "skills")
    refute File.exists?(Path.join(profile, "auth.json"))
    assert %{"account_id" => "acct-123", "email" => "codex@example.com"} = CodexAccounts.identity(source)
    refute inspect(CodexAccounts.identity(profile)) =~ "secret-token"

    # Exercise the child environment, not just the profile_env/2 return value.
    script = Path.join(home, "profile-probe.sh")
    pid_path = Path.join(home, "profile-probe.pid")

    File.write!(script, """
    test "$CODEX_HOME" = #{Aiur.Shell.escape(profile)} || exit 1
    test ! -e "$CODEX_HOME/auth.json" || exit 2
    printf '%s' "$$" > #{Aiur.Shell.escape(pid_path)}
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"account/rateLimits/read"'*) printf '%s\\n' '{"id":4,"result":{"rateLimits":{"primary":{"usedPercent":8}}}}' ;;
      esac
    done
    """)

    write_workflow_file!(Application.fetch_env!(:aiur, :workflow_file_path), codex_command: "bash " <> Aiur.Shell.escape(script))
    assert {:ok, %{"primary" => %{"usedPercent" => 8}}} = Accounts.usage("codex", "work")
    refute RemoteControl.process_alive?(pid_path |> File.read!() |> String.to_integer())
    assert Path.wildcard(Path.join(Config.workspace_root(), "codex-usage-probe-*")) == []
  end

  test "API key account registry stores named env key, never the value", %{home: home} do
    path = Path.join(home, ".aiur/.env")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "DEEPSEEK_API_KEY__WORK=deepseek-secret\n")

    :ok = Accounts.register("deepseek", "work", nil)
    account = Enum.find(Accounts.list("deepseek"), &(&1.name == "work"))
    assert account.api_key_env == "DEEPSEEK_API_KEY__WORK"
    assert Accounts.profile_env("deepseek", "work") == []
    assert :ok = AccountsCLI.login("deepseek", "work", nil)

    config = %{
      base_url: "https://example.invalid/v1",
      api_key_env: "DEEPSEEK_API_KEY",
      default_model: "deepseek-v4-flash",
      transport: :responses,
      quirks: %{}
    }

    previous = System.get_env("DEEPSEEK_API_KEY")

    try do
      System.put_env("DEEPSEEK_API_KEY", "default-key")

      assert {:ok, resolved} = OpenAIConfig.resolve(backend: "deepseek", instance: config, backend_config: %{}, account_name: "work")
      assert resolved.api_key == "deepseek-secret"
      assert resolved.api_key != "default-key"
    after
      if previous, do: System.put_env("DEEPSEEK_API_KEY", previous), else: System.delete_env("DEEPSEEK_API_KEY")
    end

    refute File.read!(Path.join(home, ".aiur/machine")) =~ "deepseek-secret"
  end

  test "API key account login registers only the named env binding", %{home: home} do
    path = Path.join(home, ".aiur/.env")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "MOONSHOT_API_KEY__TEAM=moonshot-secret\n")

    assert :ok = AccountsCLI.login("kimi", "team", nil)
    assert %{api_key_env: "MOONSHOT_API_KEY__TEAM"} = Enum.find(Accounts.list("kimi"), &(&1.name == "team"))
    refute File.read!(Path.join(home, ".aiur/machine")) =~ "moonshot-secret"
  end

  test "legacy Claude registry entries keep their names and can be rewritten safely", %{home: home} do
    path = Path.join(home, ".aiur/machine")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"accounts" => %{"old" => %{"harness" => "claude", "profile_dir" => Path.join(home, "old")}}}))

    assert Enum.any?(Accounts.list("claude"), &(&1.name == "old"))
    :ok = Accounts.register("claude", "new", nil)
    assert {:ok, %{"accounts" => entries}} = path |> File.read!() |> Jason.decode()
    assert Map.has_key?(entries, "claude:old")
    assert Map.has_key?(entries, "claude:new")
  end

  test "profile purge refuses adopted paths outside the account root", %{home: home} do
    adopted = Path.join(home, "adopted-claude")
    File.mkdir_p!(adopted)
    File.write!(Path.join(adopted, "keep.txt"), "retained")
    :ok = Accounts.register("claude", "adopted", adopted)

    assert :ok = Accounts.logout("claude", "adopted", true)
    assert File.read!(Path.join(adopted, "keep.txt")) == "retained"
  end

  test "every supported backend has a default account and API keys report unavailable usage", %{home: home} do
    for harness <- ["claude", "codex", "kimi", "deepseek", "openrouter"] do
      assert Enum.any?(Accounts.list(harness), &(&1.name == "default"))
    end

    File.mkdir_p!(Path.join(home, ".aiur"))
    File.write!(Path.join(home, ".aiur/.env"), "OPENROUTER_API_KEY__WORK=private-key\n")
    :ok = Accounts.register("openrouter", "work")
    assert {:error, :usage_unsupported} = Accounts.usage("openrouter", "work")

    for harness <- ["kimi", "deepseek", "openrouter"] do
      assert %{accounts: %{kind: :api_key, usage: :unavailable}} = CodingAgent.backends()[harness]
    end
  end

  test "Codex identity reads nested account metadata but not token values", %{home: home} do
    source = Path.join(home, ".codex")
    File.mkdir_p!(source)

    claims = %{
      "https://api.openai.com/profile" => %{"email" => "nested@example.com"},
      "https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct-nested"}
    }

    token = "header.#{Base.url_encode64(Jason.encode!(claims), padding: false)}.signature"
    File.write!(Path.join(source, "auth.json"), Jason.encode!(%{"tokens" => %{"id_token" => token, "access_token" => "never-print-this"}}))

    assert %{"account_id" => "acct-nested", "email" => "nested@example.com"} = CodexAccounts.identity(source)
    refute inspect(CodexAccounts.identity(source)) =~ "never-print-this"
  end

  test "backend capability explains native single-login backends" do
    assert {:ok, %{supported: false, reason: reason}} = Accounts.capability("muse")
    assert reason =~ "one native login"
    assert {:error, {:unsupported_account_backend, ^reason}} = Accounts.register("muse", "work", nil)
  end

  test "dispatch carries the chosen Codex profile home" do
    :ok = Accounts.register("codex", "work", nil)
    issue = %Issue{id: "codex-account", identifier: "CODEX-ACCOUNT", selected_backend: "codex"}

    {"codex", false, opts} =
      SessionLifecycle.resolve_session_options(
        issue,
        [
          account_config: %{accounts: %{"codex" => ["work"]}, account_selection: "priority"}
        ],
        nil
      )

    assert Keyword.fetch!(opts, :account_name) == "work"
    assert Keyword.fetch!(opts, :env) == [{"CODEX_HOME", Path.join([System.get_env("HOME"), ".aiur/accounts/codex/work"])}]
  end

  test "dispatch carries named API key env binding without storing key in registry", %{home: home} do
    env_path = Path.join(home, ".aiur/.env")
    File.mkdir_p!(Path.dirname(env_path))
    File.write!(env_path, "DEEPSEEK_API_KEY__WORK=top-secret\n")
    :ok = Accounts.register("deepseek", "work", nil)
    issue = %Issue{id: "deepseek-account", identifier: "DEEPSEEK-ACCOUNT", selected_backend: "deepseek"}

    {"deepseek", false, opts} =
      SessionLifecycle.resolve_session_options(
        issue,
        [
          account_config: %{accounts: %{"deepseek" => ["work"]}, account_selection: "priority"}
        ],
        nil
      )

    assert Keyword.fetch!(opts, :env) == []
    assert Keyword.fetch!(opts, :account_name) == "work"
    refute File.read!(Path.join(home, ".aiur/machine")) =~ "top-secret"
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

    assert Keyword.get(remote_opts, :env, []) == Keyword.fetch!(session_opts, :env)

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

  test "moves Claude session artifacts and merges only that session history by timestamp", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join(home, ".claude")
    destination = Path.join([home, ".aiur/accounts/claude/work"])
    session = "11111111-2222-4333-8444-555555555555"
    project = RemoteControl.workspace_slug("/repo")
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
    transcript = Path.join([source, "projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])
    File.mkdir_p!(Path.dirname(transcript))
    File.write!(transcript, "transcript")

    assert :ok = Accounts.move_session("claude", "work", "default", session, "/repo")
    refute File.exists?(transcript)
    assert File.read!(Path.join([home, ".claude", "projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])) == "transcript"
  end

  test "skips a destination artifact symlink that resolves to the source file", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    :ok = Accounts.register("claude", "work", nil)
    source = Path.join(home, ".claude")
    destination = Path.join([home, ".aiur/accounts/claude/work"])
    session = "11111111-2222-4333-8444-555555555555"
    relative = Path.join(["projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])
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
    transcript = Path.join([source, "projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])
    File.mkdir_p!(Path.dirname(transcript))
    File.write!(transcript, "transcript")
    rm = fn path -> if path == transcript, do: {:error, :injected_delete_failure}, else: File.rm_rf(path) end

    assert {:error, {:source_delete_failed, :injected_delete_failure}} =
             Accounts.move_session("claude", "default", "work", session, "/repo", same_device: false, rm_rf: rm)

    assert File.read!(transcript) == "transcript"
    refute File.exists?(Path.join([home, ".aiur/accounts/claude/work", "projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"]))
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
    destination_artifact = Path.join([destination, "projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])
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
    project = Path.join([source, "projects", RemoteControl.workspace_slug("/repo")])
    File.mkdir_p!(project)
    transcript = Path.join(project, session <> ".jsonl")
    File.write!(transcript, "source")
    file_history = Path.join([source, "file-history", session])
    File.mkdir_p!(file_history)
    File.write!(Path.join(file_history, "snapshot"), "history")
    conflict = Path.join([destination, "projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])

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
    project = Path.join([source, "projects", RemoteControl.workspace_slug("/repo")])
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
    assert File.read!(Path.join([destination, "projects", RemoteControl.workspace_slug("/repo"), session <> ".jsonl"])) == "verified transcript"
  end
end
