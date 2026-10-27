defmodule Aiur.EnvStartupChecksTest do
  use ExUnit.Case, async: false
  import Bitwise
  import ExUnit.CaptureLog

  alias Aiur.Application.StartupChecks
  alias Aiur.Env

  defmodule FirstCheck do
    @behaviour Aiur.Env.StartupCheck
    @impl true
    def errors(env), do: ["first: #{env["MARKER"]}"]
  end

  defmodule SecondCheck do
    @behaviour Aiur.Env.StartupCheck
    @impl true
    def errors(_env), do: ["second"]
  end

  defmodule Keyring do
    def keyring_token do
      send(self(), :configured_keyring_lookup)
      "fixture-token"
    end
  end

  setup do
    for key <- [:env_startup_checks, :keyring_token_fun_module] do
      original = Application.fetch_env(:aiur, key)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:aiur, key, value)
          :error -> Application.delete_env(:aiur, key)
        end
      end)
    end

    :ok
  end

  test "registered checks receive the environment and follow schema errors in registry order" do
    Application.put_env(:aiur, :env_startup_checks, [FirstCheck, SecondCheck])
    env = %{"AIUR_DEBUG" => "banana", "AIUR_DASHBOARD_USERNAME" => "operator", "MARKER" => "fixture"}
    assert {:error, [type_error, group_error, "first: fixture", "second"]} = Env.validate(env)
    assert type_error == "AIUR_DEBUG must be a boolean (1, true, yes, 0, false, no), got \"banana\""
    assert group_error =~ "Set both or neither"
  end

  test "hosted preflight reports all missing secret names without echoing present values" do
    settings = %{
      tracker: %{kind: "github"},
      server: %{host: "0.0.0.0"},
      webhooks: %{repos: []},
      agent: %{priority: []}
    }

    env = %{
      "AIUR_SECRETS_FROM_ENV" => "1",
      "GITHUB_APP_ID" => "app-id-value",
      "AIUR_DASHBOARD_USERNAME" => "operator-name",
      "AIUR_SECRET_KEY_BASE" => String.duplicate("x", 64),
      "AIUR_STATE_PERSISTENT" => "0"
    }

    error = assert_raise ArgumentError, fn -> StartupChecks.validate_secrets!(settings, env) end
    message = Exception.message(error)
    assert message =~ "GITHUB_APP_INSTALLATION_ID"
    assert message =~ "GITHUB_APP_PRIVATE_KEY"
    assert message =~ "AIUR_DASHBOARD_PASSWORD"
    refute message =~ "app-id-value"
    refute message =~ "operator-name"
    refute message =~ String.duplicate("x", 64)
  end

  test "consumer deployment rejects the subscription token while operator deployment accepts it" do
    env = %{"CLAUDE_CODE_OAUTH_TOKEN" => "subscription-token"}

    agent = %{kind: "claude", priority: [], backend_configs: %{}}
    consumer = %{instance: %{mode: "hosted", deployment_kind: "consumer"}, agent: agent}
    operator = %{instance: %{mode: "hosted", deployment_kind: "operator"}, agent: agent}

    assert {:error, messages} = StartupChecks.validate_deployment_credentials(consumer, env)
    message = Enum.join(messages, " ")
    assert message =~ "CLAUDE_CODE_OAUTH_TOKEN"
    refute message =~ "subscription-token"

    assert :ok = StartupChecks.validate_deployment_credentials(operator, env)

    assert_raise ArgumentError, ~r/CLAUDE_CODE_OAUTH_TOKEN/, fn ->
      StartupChecks.validate_deployment_credentials!(consumer, env)
    end
  end

  test "hosted Codex credentials use the configured persistent CODEX_HOME auth file" do
    root = Aiur.TestSupport.tmp_root!("hosted-codex-auth")
    home = Path.join(root, "codex")
    File.mkdir_p!(home)
    auth_path = Path.join(home, "auth.json")
    File.write!(auth_path, Jason.encode!(%{"auth_mode" => "chatgptAuthTokens"}))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    settings = %{
      instance: %{mode: "hosted", deployment_kind: "operator"},
      agent: %{kind: "codex", priority: [], backend_configs: %{}}
    }

    assert :ok = StartupChecks.validate_deployment_credentials(settings, %{"CODEX_HOME" => home})
    consumer = put_in(settings.instance.deployment_kind, "consumer")
    assert {:error, messages} = StartupChecks.validate_deployment_credentials(consumer, %{"CODEX_HOME" => home})
    assert Enum.any?(messages, &String.contains?(&1, "CODEX_HOME/auth.json"))
  end

  test "hosted startup prepares persistent Codex home and preserves explicit configuration" do
    root = Aiur.TestSupport.tmp_root!("hosted-codex-home")
    state_dir = Path.join(root, "state")
    explicit_home = Path.join(root, "explicit-codex")
    original_codex_home = System.get_env("CODEX_HOME")

    on_exit(fn ->
      restore_env("CODEX_HOME", original_codex_home)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    hosted = {:ok, %{instance: %{mode: "hosted"}}}
    configured = StartupChecks.configure_codex_home(hosted, %{"AIUR_BG_STATE_DIR" => state_dir})
    expected_home = Path.join(state_dir, "codex")
    assert configured["CODEX_HOME"] == expected_home
    assert System.get_env("CODEX_HOME") == expected_home
    assert File.stat!(expected_home).mode |> band(0o777) == 0o700

    explicit = StartupChecks.configure_codex_home(hosted, %{"AIUR_BG_STATE_DIR" => state_dir, "CODEX_HOME" => explicit_home})
    assert explicit["CODEX_HOME"] == explicit_home
    assert File.stat!(explicit_home).mode |> band(0o777) == 0o700

    local_env = %{"CODEX_HOME" => "unchanged", "AIUR_BG_STATE_DIR" => state_dir}
    assert StartupChecks.configure_codex_home({:ok, %{instance: %{mode: "local"}}}, local_env) == local_env
    assert System.get_env("CODEX_HOME") == explicit_home
  end

  test "settings result validation clears local and hosted rotated provider holds" do
    root = Aiur.TestSupport.tmp_root!("startup-auth-hold-reconcile")
    state_dir = Path.join(root, "hosted-state")
    workflow_path = Path.join([root, "local", ".aiur", "config"])
    File.mkdir_p!(Path.dirname(workflow_path))

    previous_workflow = Application.fetch_env(:aiur, :workflow_file_path)
    previous_mode = Application.fetch_env(:aiur, :booted_instance_mode)
    previous_codex_home = System.get_env("CODEX_HOME")

    on_exit(fn ->
      restore_app_env(:workflow_file_path, previous_workflow)
      restore_app_env(:booted_instance_mode, previous_mode)
      restore_env("CODEX_HOME", previous_codex_home)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    local_settings = startup_settings("local")
    local_ledger = Path.join(Path.dirname(workflow_path), "model-usage.json")
    Aiur.Workflow.set_workflow_file_path(workflow_path)
    Application.put_env(:aiur, :booted_instance_mode, "local")
    assert {:ok, :first} = Aiur.ModelAvailability.mark_auth_rejected("claude", "unavailable", path: local_ledger)

    assert :ok =
             StartupChecks.validate_environment({:ok, local_settings}, %{
               "ANTHROPIC_API_KEY" => "rotated-local-key",
               "GITHUB_TOKEN" => "fixture-token"
             })

    refute Aiur.ModelAvailability.auth_rejected?("claude", path: local_ledger)

    hosted_settings = startup_settings("hosted")
    hosted_ledger = Path.join(state_dir, "model-usage.json")
    assert {:ok, :first} = Aiur.ModelAvailability.mark_auth_rejected("claude", "old-hosted-key", path: hosted_ledger)

    hosted_env = %{
      "AIUR_BG_STATE_DIR" => state_dir,
      "ANTHROPIC_API_KEY" => "rotated-hosted-key",
      "GITHUB_TOKEN" => "fixture-token"
    }

    assert :ok = StartupChecks.validate_environment({:ok, hosted_settings}, hosted_env)
    refute Aiur.ModelAvailability.auth_rejected?("claude", path: hosted_ledger)
  end

  test "failed auth-hold ledger rewrite is logged while startup continues and retains the hold" do
    root = Aiur.TestSupport.tmp_root!("startup-auth-hold-read-only")
    workflow_path = Path.join([root, ".aiur", "config"])
    ledger_dir = Path.dirname(workflow_path)
    File.mkdir_p!(ledger_dir)
    previous_workflow = Application.fetch_env(:aiur, :workflow_file_path)
    previous_mode = Application.fetch_env(:aiur, :booted_instance_mode)

    on_exit(fn ->
      File.chmod!(ledger_dir, 0o700)
      restore_app_env(:workflow_file_path, previous_workflow)
      restore_app_env(:booted_instance_mode, previous_mode)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    Aiur.Workflow.set_workflow_file_path(workflow_path)
    Application.put_env(:aiur, :booted_instance_mode, "local")
    ledger = Path.join(ledger_dir, "model-usage.json")
    assert {:ok, :first} = Aiur.ModelAvailability.mark_auth_rejected("claude", "unavailable", path: ledger)
    File.chmod!(ledger_dir, 0o500)

    log =
      capture_log(fn ->
        assert :ok = StartupChecks.validate_environment({:ok, startup_settings("local")}, %{})
      end)

    assert log =~ "could not reconcile provider credential hold for claude; keeping it in place"
    assert Aiur.ModelAvailability.auth_rejected?("claude", path: ledger)
  end

  defp startup_settings(mode) do
    %{
      instance: %{mode: mode, deployment_kind: "operator"},
      tracker: %{kind: "memory"},
      server: %{host: "127.0.0.1"},
      webhooks: %{repos: []},
      agent: %{kind: "claude", priority: ["claude"], routing: %{}, backend_configs: %{}}
    }
  end

  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:aiur, key, value)
  defp restore_app_env(key, :error), do: Application.delete_env(:aiur, key)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  test "hosted startup requires credentials for backend routes" do
    settings = %{
      instance: %{mode: "hosted", deployment_kind: "operator"},
      agent: %{kind: "claude", priority: [], routing: %{1 => "codex:gpt-5.5"}, backend_configs: %{}}
    }

    assert {:error, messages} = StartupChecks.validate_deployment_credentials(settings, %{})
    assert Enum.any?(messages, &String.contains?(&1, "CODEX_HOME/auth.json"))
  end

  test "hosted Linear configuration does not require GitHub credentials" do
    settings = %{
      tracker: %{kind: "linear"},
      server: %{host: "127.0.0.1"},
      webhooks: %{repos: []},
      agent: %{kind: "codex", priority: []}
    }

    env = %{"AIUR_SECRETS_FROM_ENV" => "1", "AIUR_STATE_PERSISTENT" => "1", "LINEAR_API_KEY" => "linear-key"}

    assert :ok = StartupChecks.validate_secrets(settings, env)
  end

  test "outbound webhook startup requires one valid 256-bit Standard Webhooks secret only when a URL is configured" do
    disabled = %{events: %{export: %{enabled: false}}}
    journal_only = %{events: %{export: %{enabled: true, webhook_url: nil}}}
    enabled = %{events: %{export: %{enabled: true, webhook_url: "https://consumer.example.com/events"}}}
    valid = "whsec_" <> Base.encode64(String.duplicate("k", 32))

    assert :ok = StartupChecks.validate_outbound_export(disabled, %{})
    assert :ok = StartupChecks.validate_outbound_export(journal_only, %{})
    assert {:error, [missing]} = StartupChecks.validate_outbound_export(enabled, %{})
    assert missing =~ "AIUR_OUTBOUND_WEBHOOK_SECRET"

    for invalid <- ["", "not-prefixed", "whsec_not-base64", "whsec_" <> Base.encode64("too-short")] do
      assert {:error, [message]} =
               StartupChecks.validate_outbound_export(enabled, %{"AIUR_OUTBOUND_WEBHOOK_SECRET" => invalid})

      assert message =~ "AIUR_OUTBOUND_WEBHOOK_SECRET"
      if invalid != "", do: refute(message =~ invalid)
    end

    assert :ok =
             StartupChecks.validate_outbound_export(enabled, %{
               "AIUR_OUTBOUND_WEBHOOK_SECRET" => valid
             })
  end

  test "hosted GitHub startup names the opt-in when only a PAT is configured" do
    settings = %{tracker: %{kind: "github"}, instance: %{mode: "hosted"}}
    env = %{"GITHUB_TOKEN" => "pat-secret"}

    assert {:error, message} = StartupChecks.validate_github_auth(settings, env)
    assert message =~ "AIUR_GITHUB_ALLOW_PAT=1"
    refute message =~ "pat-secret"
  end

  test "environment-only GitHub startup names the App and PAT opt-in before generic secret checks" do
    settings = %{tracker: %{kind: "github"}}
    env = %{"AIUR_SECRETS_FROM_ENV" => "1"}

    error = assert_raise ArgumentError, fn -> StartupChecks.validate_auth_before_secrets!(settings, env) end
    message = Exception.message(error)
    assert message =~ "GITHUB_APP_ID"
    assert message =~ "AIUR_GITHUB_ALLOW_PAT=1"
  end

  test "hosted GitHub startup permits the opted-in PAT fallback" do
    settings = %{tracker: %{kind: "github"}, instance: %{mode: "hosted"}}
    env = %{"GITHUB_TOKEN" => "pat-secret", "AIUR_GITHUB_ALLOW_PAT" => "1"}

    assert StartupChecks.validate_github_auth(settings, env) == :ok
  end

  test "Google OAuth client id and secret must be configured together" do
    assert {:error, errors} = Env.validate(%{"AIUR_GOOGLE_CLIENT_ID" => "client-id"})
    assert Enum.any?(errors, &(&1 =~ "Google sign-in credentials are partially configured"))
    assert Enum.any?(errors, &(&1 =~ "AIUR_GOOGLE_CLIENT_SECRET"))
  end

  test "missing registry still rejects an invalid supervisor token without exposing it" do
    Application.delete_env(:aiur, :env_startup_checks)
    token = "secret-short-token"
    assert {:error, [message]} = Env.validate(%{"AIUR_SUPERVISOR_TOKEN" => token})

    assert message ==
             "AIUR_SUPERVISOR_TOKEN must be a bearer-safe token of at least 32 bytes with no surrounding whitespace"

    refute message =~ token
  end

  test "configured keyring module supplies the default while explicit functions take precedence" do
    Application.put_env(:aiur, :keyring_token_fun_module, Keyring)
    assert :ok = Env.validate_startup!(%{})
    assert_received :configured_keyring_lookup

    assert_raise ArgumentError, fn ->
      Env.validate_startup!(%{}, keyring_fun: fn -> nil end)
    end

    refute_received :configured_keyring_lookup
  end

  test "pure parser and init compatibility delegate preserve empty values, quotes and duplicate order" do
    content = "# comment\nA=first\nA=second\nB=\"x=y\"\nC='quoted'\nEMPTY=\nexport D=legacy\n"
    expected = [{"A", "first"}, {"A", "second"}, {"B", "x=y"}, {"C", "quoted"}, {"EMPTY", ""}, {"export D", "legacy"}]
    assert Aiur.Env.Dotenv.parse(content, include_empty: true) == expected
    assert Aiur.Init.Dotenv.parse(content, include_empty: true) == expected
  end
end
