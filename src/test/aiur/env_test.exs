defmodule Aiur.EnvTest do
  use ExUnit.Case, async: false

  alias Aiur.Env
  alias Aiur.Env.Schema

  # Token- and secret-shaped values seeded into the process environment to
  # prove they never reach the generated example, logs, or error output.
  @secret_values %{
    "GITHUB_TOKEN" => "ghp_FAKE_TOKEN_12345",
    "ELEVENLABS_API_KEY" => "sk-fake-elevenlabs",
    "AIUR_DASHBOARD_PASSWORD" => "sup3r-secret-password",
    "AIUR_ERLANG_COOKIE" => "fake-cookie-secret",
    "AIUR_GITHUB_WEBHOOK_SECRET" => "fake-webhook-secret"
  }

  setup do
    original = Map.take(System.get_env(), Map.keys(@secret_values))
    Enum.each(Map.keys(@secret_values), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(Map.keys(@secret_values), &System.delete_env/1)
      Enum.each(original, fn {key, value} -> System.put_env(key, value) end)
    end)

    :ok
  end

  describe "validate/1 — type errors fail at startup, not first use" do
    test "a wrong-typed integer fails naming the variable and the expectation" do
      assert {:error, [message]} = Env.validate(%{"AIUR_OPENCODE_BRIDGE_PORT" => "banana"})
      assert message =~ "AIUR_OPENCODE_BRIDGE_PORT"
      assert message =~ "must be an integer"
    end

    test "a wrong-typed boolean fails naming the variable and the expectation" do
      assert {:error, [message]} = Env.validate(%{"AIUR_DEBUG" => "banana"})
      assert message =~ "AIUR_DEBUG"
      assert message =~ "must be a boolean"
    end

    test "values the app already recognises pass unchanged" do
      assert Env.validate(%{"AIUR_OPENCODE_BRIDGE_PORT" => "8080"}) == {:ok, :ok}
      assert Env.validate(%{"AIUR_DEBUG" => "1"}) == {:ok, :ok}
      assert Env.validate(%{"AIUR_DEBUG" => "true"}) == {:ok, :ok}
      assert Env.validate(%{"AIUR_PREWARM_DISABLED" => "no"}) == {:ok, :ok}
      assert Env.validate(%{"AIUR_DEBUG" => "0"}) == {:ok, :ok}
    end

    test "an empty or absent value is not a type error" do
      assert Env.validate(%{"AIUR_OPENCODE_BRIDGE_PORT" => ""}) == {:ok, :ok}
      assert Env.validate(%{}) == {:ok, :ok}
    end

    test "secret values never produce a type error naming their content" do
      assert Env.validate(%{"GITHUB_TOKEN" => @secret_values["GITHUB_TOKEN"]}) == {:ok, :ok}
    end
  end

  describe "validate/1 — credential groups are all-or-nothing" do
    test "a partially configured GitHub App group fails naming the missing members" do
      assert {:error, [message]} = Env.validate(%{"GITHUB_APP_ID" => "123"})
      assert message =~ "GITHUB_APP_INSTALLATION_ID"
      assert message =~ "GITHUB_APP_PRIVATE_KEY_PATH"
      assert message =~ "GITHUB_APP_PRIVATE_KEY"
    end

    test "a complete GitHub App group passes" do
      env = %{
        "GITHUB_APP_ID" => "123",
        "GITHUB_APP_INSTALLATION_ID" => "456",
        "GITHUB_APP_PRIVATE_KEY_PATH" => "/tmp/app.pem"
      }

      assert Env.validate(env) == {:ok, :ok}
    end

    test "an inline private key satisfies the path-or-key alternative" do
      env = %{
        "GITHUB_APP_ID" => "123",
        "GITHUB_APP_INSTALLATION_ID" => "456",
        "GITHUB_APP_PRIVATE_KEY" => "-----BEGIN RSA PRIVATE KEY-----"
      }

      assert Env.validate(env) == {:ok, :ok}
    end

    test "a fully absent group is a supported setup, never an error" do
      assert Env.validate(%{}) == {:ok, :ok}
    end

    test "a partially configured dashboard group fails naming the missing member" do
      assert {:error, [message]} = Env.validate(%{"AIUR_DASHBOARD_USERNAME" => "operator"})
      assert message =~ "AIUR_DASHBOARD_PASSWORD"
      assert message =~ "Set both or neither"
    end

    test "both dashboard credentials pass" do
      env = %{"AIUR_DASHBOARD_USERNAME" => "operator", "AIUR_DASHBOARD_PASSWORD" => "pw"}
      assert Env.validate(env) == {:ok, :ok}
    end
  end

  describe "validate_startup!/1 — the GitHub credential boot gate" do
    test "aborts when no GitHub credential is configured, naming the requirement" do
      error = assert_raise ArgumentError, fn -> Env.validate_startup!(%{}, require_github_credential: true) end
      assert error.message =~ "GITHUB_TOKEN"
      assert error.message =~ "GITHUB_APP_ID"
    end

    test "GITHUB_TOKEN alone satisfies the requirement" do
      assert :ok = Env.validate_startup!(%{"GITHUB_TOKEN" => "ghp_real"}, require_github_credential: true)
    end

    test "a complete GitHub App set satisfies the requirement without GITHUB_TOKEN" do
      env = %{
        "GITHUB_APP_ID" => "123",
        "GITHUB_APP_INSTALLATION_ID" => "456",
        "GITHUB_APP_PRIVATE_KEY_PATH" => "/tmp/app.pem"
      }

      assert :ok = Env.validate_startup!(env, require_github_credential: true)
    end

    test "a non-GitHub tracker does not demand GitHub credentials" do
      assert :ok = Env.validate_startup!(%{}, require_github_credential: false)
    end

    test "a partial GitHub App group still aborts even when GITHUB_TOKEN is absent" do
      error =
        assert_raise ArgumentError, fn ->
          Env.validate_startup!(%{"GITHUB_APP_ID" => "123"}, require_github_credential: true)
        end

      assert error.message =~ "GITHUB_APP_ID"
      assert error.message =~ "GITHUB_APP_INSTALLATION_ID"
    end

    test "the raised message names the variable and never the secret value" do
      env = %{
        "GITHUB_TOKEN" => @secret_values["GITHUB_TOKEN"],
        "GITHUB_APP_ID" => "123",
        "AIUR_DASHBOARD_USERNAME" => "operator"
      }

      error = assert_raise ArgumentError, fn -> Env.validate_startup!(env, require_github_credential: true) end
      refute error.message =~ "ghp_FAKE_TOKEN_12345"
      assert error.message =~ "AIUR_DASHBOARD_PASSWORD"
    end
  end

  describe "render_example/0 — .env.example generation" do
    test "renders every non-example:false schema var with a one-line purpose" do
      rendered = Env.render_example()

      Enum.each(Schema.example_names(), fn name ->
        assert rendered =~ ~r/^#{Regex.escape(name)}=/m,
               "expected #{name} to be rendered in the example"
      end)
    end

    test "sections carry the required/optional group headers" do
      rendered = Env.render_example()
      assert rendered =~ "## Required"
      assert rendered =~ "## Optional - GitHub App auth."
      assert rendered =~ "## Optional - Aiur dashboard."
    end

    test "secrets render as an empty placeholder, never a real value" do
      rendered = Env.render_example()

      # Secrets with a fetch note still carry an empty value before the comment.
      assert rendered =~ ~r/^GITHUB_TOKEN=\s+#/m
      assert rendered =~ ~r/^ELEVENLABS_API_KEY=\s+#/m
      # A secret with nothing to fetch renders as a bare, value-less key.
      assert rendered =~ ~r/^GITHUB_APP_PRIVATE_KEY=$/m
      assert rendered =~ ~r/^AIUR_DASHBOARD_PASSWORD=\s+#/m
    end

    test "never contains any real value from the process environment" do
      Enum.each(@secret_values, fn {key, value} -> System.put_env(key, value) end)
      rendered = Env.render_example()

      Enum.each(Map.values(@secret_values), fn value ->
        refute rendered =~ value, "rendered example leaked the real value #{inspect(value)}"
      end)
    end

    test "right-hand fetch notes are aligned to a common column" do
      rendered = Env.render_example()

      # GITHUB_TOKEN carries a fetch note; its `#` must sit at the aligned column
      # rather than immediately after the value.
      assert rendered =~ ~r/^GITHUB_TOKEN=\s+# github\.com\/settings\/tokens/m
    end
  end

  describe "disabled_integrations/1 — one startup line naming what is off" do
    test "an unconfigured environment names every optional integration once" do
      disabled = Env.disabled_integrations(%{})
      joined = Enum.join(disabled, " ")

      assert disabled != []
      assert joined =~ "webhooks off"
      assert joined =~ "voice off"
      assert joined =~ "dashboard credentials off"
      assert joined =~ "Supervisor Decision API off"
    end

    test "a fully configured environment reports nothing disabled" do
      env = %{
        "GITHUB_TOKEN" => "ghp_x",
        "GITHUB_APP_ID" => "123",
        "GITHUB_APP_INSTALLATION_ID" => "456",
        "GITHUB_APP_PRIVATE_KEY_PATH" => "/tmp/app.pem",
        "AIUR_GITHUB_WEBHOOK_SECRET" => "s",
        "ELEVENLABS_API_KEY" => "k",
        "AIUR_DASHBOARD_USERNAME" => "u",
        "AIUR_DASHBOARD_PASSWORD" => "p",
        "AIUR_SUPERVISOR_TOKEN" => "t",
        "DEEPSEEK_API_KEY" => "d",
        "LINEAR_API_KEY" => "l"
      }

      assert Env.disabled_integrations(env) == []
    end

    test "GitHub App auth without GITHUB_TOKEN is reported as the active auth" do
      env = %{
        "GITHUB_APP_ID" => "123",
        "GITHUB_APP_INSTALLATION_ID" => "456",
        "GITHUB_APP_PRIVATE_KEY_PATH" => "/tmp/app.pem"
      }

      disabled = Env.disabled_integrations(env)
      assert Enum.any?(disabled, &(&1 =~ "GITHUB_TOKEN fallback off"))
    end

    test "warn_disabled_integrations/1 logs exactly one line" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Env.warn_disabled_integrations(%{})
        end)

      assert length(Regex.scan(~r/disabled_integrations=/, log)) == 1
    end
  end

  describe "precedence conflicts — ~/.aiur/.env vs ./.env" do
    setup do
      home_env = Path.join(System.tmp_dir!(), "aiur-env-test-home-#{System.pid()}-#{System.unique_integer([:positive])}.env")
      repo_env = Path.join(System.tmp_dir!(), "aiur-env-test-repo-#{System.pid()}-#{System.unique_integer([:positive])}.env")

      on_exit(fn ->
        File.rm(home_env)
        File.rm(repo_env)
      end)

      %{home_env: home_env, repo_env: repo_env}
    end

    test "a variable set to different values in both files is reported",
         %{home_env: home_env, repo_env: repo_env} do
      File.write!(home_env, "AIUR_DASHBOARD_PASSWORD=one\nGITHUB_TOKEN=home-token\n")
      File.write!(repo_env, "AIUR_DASHBOARD_PASSWORD=two\nGITHUB_TOKEN=home-token\n")

      assert [{key, "one", "two"}] = Env.precedence_conflicts(home_env, repo_env)
      assert key == "AIUR_DASHBOARD_PASSWORD"
    end

    test "matching values and single-sided vars are not conflicts",
         %{home_env: home_env, repo_env: repo_env} do
      File.write!(home_env, "AIUR_DEBUG=1\nAIUR_LOGS_ROOT=/home/logs\n")
      File.write!(repo_env, "AIUR_DEBUG=1\nAIUR_BASE_BRANCH=main\n")

      assert Env.precedence_conflicts(home_env, repo_env) == []
    end

    test "warnings name the variable but never either value",
         %{home_env: home_env, repo_env: repo_env} do
      File.write!(home_env, "AIUR_DASHBOARD_PASSWORD=one\n")
      File.write!(repo_env, "AIUR_DASHBOARD_PASSWORD=two\n")

      [warning] = Env.precedence_warnings(Env.precedence_conflicts(home_env, repo_env))

      assert warning =~ "AIUR_DASHBOARD_PASSWORD"
      refute warning =~ "one"
      refute warning =~ "two"
    end
  end

  describe "boot hook wiring" do
    test "maybe_validate_environment/0 is a safe no-op in the test environment" do
      assert :ok = Aiur.Application.maybe_validate_environment()
    end
  end
end
