defmodule Aiur.EnvStartupChecksTest do
  use ExUnit.Case, async: false

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
