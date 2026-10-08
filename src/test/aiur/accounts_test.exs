defmodule Aiur.AccountsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.Accounts
  alias Aiur.Accounts.Shims.Claude
  alias Aiur.Accounts.Shims.Codex, as: CodexAccounts
  alias Aiur.Accounts.UsageReadings
  alias Aiur.AccountsCLI
  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.CodingAgent
  alias Aiur.Issue
  alias Aiur.OpenAICompat.Config, as: OpenAIConfig

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
    assert is_tuple(Accounts.usage("codex", "work"))
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

  test "accounts json reports daemon not running while retaining identity", %{home: home} do
    File.mkdir_p!(Path.join(home, ".claude"))
    File.write!(Path.join(home, ".claude.json"), ~s({"oauthAccount":{"emailAddress":"dev@example.com"}}))

    output = capture_io(fn -> assert :ok = Aiur.AccountsCLI.accounts(true, fn _names -> %{} end) end)
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
