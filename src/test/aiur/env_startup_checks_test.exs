defmodule Aiur.EnvStartupChecksTest do
  use ExUnit.Case, async: false

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
