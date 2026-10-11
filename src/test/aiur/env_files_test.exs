defmodule Aiur.EnvFilesTest do
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
    original_keyring_timeout = System.get_env("AIUR_GH_KEYRING_TIMEOUT_MS")
    System.delete_env("AIUR_GH_KEYRING_TIMEOUT_MS")

    on_exit(fn ->
      Enum.each(Map.keys(@secret_values), &System.delete_env/1)
      Enum.each(original, fn {key, value} -> System.put_env(key, value) end)

      case original_keyring_timeout do
        nil -> System.delete_env("AIUR_GH_KEYRING_TIMEOUT_MS")
        value -> System.put_env("AIUR_GH_KEYRING_TIMEOUT_MS", value)
      end
    end)

    :ok
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
      # The supervisor token deliberately carries no inline fetch note: the
      # dotenv loaders do not strip inline comments, so a copied .env.example
      # must never feed the literal `# openssl ...` hint in as the token value.
      assert rendered =~ ~r/^AIUR_SUPERVISOR_TOKEN=$/m
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

    test "a blank supervisor token leaves the Decision API reported off" do
      for token <- [nil, "", "   "] do
        joined = %{"AIUR_SUPERVISOR_TOKEN" => token} |> Env.disabled_integrations() |> Enum.join(" ")
        assert joined =~ "Supervisor Decision API off"
      end
    end

    test "a present-but-invalid supervisor token is a startup error, not reported off" do
      # An unusable configured value aborts the boot gate rather than quietly
      # reporting the optional API as disabled, so it must not name the API off.
      env = %{"AIUR_SUPERVISOR_TOKEN" => String.duplicate("a", 31)}
      joined = env |> Env.disabled_integrations() |> Enum.join(" ")
      refute joined =~ "Supervisor Decision API off"
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
        "AIUR_SUPERVISOR_TOKEN" => String.duplicate("t", 32),
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
      home_env = Aiur.TestSupport.tmp_root!("aiur-env-test-home") <> ".env"
      repo_env = Aiur.TestSupport.tmp_root!("aiur-env-test-repo") <> ".env"

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

    test "warnings name the variable but never either value, and say the repo value wins",
         %{home_env: home_env, repo_env: repo_env} do
      File.write!(home_env, "AIUR_DASHBOARD_PASSWORD=one\n")
      File.write!(repo_env, "AIUR_DASHBOARD_PASSWORD=two\n")

      [warning] = Env.precedence_warnings(Env.precedence_conflicts(home_env, repo_env))

      assert warning =~ "AIUR_DASHBOARD_PASSWORD"
      assert warning =~ "the ./.env value wins and the ~/.aiur/.env value is ignored"
      refute warning =~ "one"
      refute warning =~ "two"
    end

    # #2638: the launcher drops every global GitHub credential once the repo
    # file declares any member of the group, so a global App next to a
    # repo-local token is reported even though the names never overlap.
    test "global GitHub credentials are reported as ignored when the repo declares its own",
         %{home_env: home_env, repo_env: repo_env} do
      File.write!(
        home_env,
        "GITHUB_APP_ID=1\nGITHUB_APP_INSTALLATION_ID=2\nGITHUB_APP_PRIVATE_KEY_PATH=/k\nAIUR_DEBUG=1\n"
      )

      File.write!(repo_env, "GITHUB_TOKEN=repo-token\n")

      assert Env.precedence_conflicts(home_env, repo_env) == [
               {"GITHUB_APP_ID", "1", nil},
               {"GITHUB_APP_INSTALLATION_ID", "2", nil},
               {"GITHUB_APP_PRIVATE_KEY_PATH", "/k", nil}
             ]

      warnings = Env.precedence_warnings(Env.precedence_conflicts(home_env, repo_env))
      assert length(warnings) == 3
      assert Enum.all?(warnings, &(&1 =~ "declares its own GitHub credential"))
      refute Enum.any?(warnings, &(&1 =~ "/k"))
    end

    test "a blank placeholder GITHUB_TOKEN= in the repo file is not a declaration",
         %{home_env: home_env, repo_env: repo_env} do
      File.write!(home_env, "GITHUB_APP_ID=1\nGITHUB_APP_INSTALLATION_ID=2\nGITHUB_APP_PRIVATE_KEY_PATH=/k\n")
      File.write!(repo_env, "GITHUB_TOKEN=\n")

      assert Env.precedence_conflicts(home_env, repo_env) == []
    end

    test "a global App with no repo-local credential is not a conflict",
         %{home_env: home_env, repo_env: repo_env} do
      File.write!(home_env, "GITHUB_APP_ID=1\nGITHUB_APP_INSTALLATION_ID=2\nGITHUB_APP_PRIVATE_KEY_PATH=/k\n")
      File.write!(repo_env, "AIUR_BASE_BRANCH=main\n")

      assert Env.precedence_conflicts(home_env, repo_env) == []
    end
  end

  describe "boot hook wiring" do
    test "maybe_validate_environment/0 is a safe no-op in the test environment" do
      assert :ok = Aiur.Application.maybe_validate_environment()
    end
  end
end
