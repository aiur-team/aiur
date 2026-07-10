defmodule Aiur.Config.Schema.EnvResolverTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema.EnvResolver

  describe "env_reference_name/1" do
    test "returns {:ok, name} for a valid $NAME reference" do
      assert EnvResolver.env_reference_name("$MY_VAR") == {:ok, "MY_VAR"}
      assert EnvResolver.env_reference_name("$_LEADING_UNDERSCORE") == {:ok, "_LEADING_UNDERSCORE"}
    end

    test "returns :error for an invalid $NAME (starts with digit)" do
      assert EnvResolver.env_reference_name("$123INVALID") == :error
    end

    test "returns :error for a value that contains a hyphen" do
      assert EnvResolver.env_reference_name("$MY-VAR") == :error
    end

    test "returns :error for a non-$ prefixed string" do
      assert EnvResolver.env_reference_name("plain") == :error
    end

    test "returns :error for a bare $ with no name" do
      assert EnvResolver.env_reference_name("$") == :error
    end
  end

  describe "normalize_secret_value/1" do
    test "returns nil for an empty string" do
      assert EnvResolver.normalize_secret_value("") == nil
    end

    test "returns the value for a non-empty string" do
      assert EnvResolver.normalize_secret_value("token") == "token"
    end

    test "returns nil for non-binary input" do
      assert EnvResolver.normalize_secret_value(nil) == nil
      assert EnvResolver.normalize_secret_value(42) == nil
    end
  end

  describe "resolve_env_value/2" do
    test "resolves $NAME from the environment when set" do
      System.put_env("AIUR_TEST_RESOLVE_VAL_1", "from-env")
      on_exit(fn -> System.delete_env("AIUR_TEST_RESOLVE_VAL_1") end)

      assert EnvResolver.resolve_env_value("$AIUR_TEST_RESOLVE_VAL_1", "fallback") == "from-env"
    end

    test "returns fallback when the env var is missing" do
      System.delete_env("AIUR_TEST_RESOLVE_VAL_MISSING")

      assert EnvResolver.resolve_env_value("$AIUR_TEST_RESOLVE_VAL_MISSING", "fallback") ==
               "fallback"
    end

    test "returns nil when the env var is an empty string" do
      System.put_env("AIUR_TEST_RESOLVE_VAL_EMPTY", "")
      on_exit(fn -> System.delete_env("AIUR_TEST_RESOLVE_VAL_EMPTY") end)

      assert EnvResolver.resolve_env_value("$AIUR_TEST_RESOLVE_VAL_EMPTY", "fallback") == nil
    end

    test "passes through a non-$REF value as-is" do
      assert EnvResolver.resolve_env_value("literal", "fallback") == "literal"
    end
  end

  describe "resolve_secret_setting/2" do
    test "returns the config value when it is a non-env literal" do
      assert EnvResolver.resolve_secret_setting("mytoken", nil) == "mytoken"
    end

    test "returns the fallback when the config value is nil" do
      assert EnvResolver.resolve_secret_setting(nil, "fallback") == "fallback"
    end

    test "returns nil when the config value is nil and the fallback is empty string" do
      assert EnvResolver.resolve_secret_setting(nil, "") == nil
    end

    test "resolves $ENV_REF from the environment" do
      System.put_env("AIUR_TEST_SECRET_1", "resolved-secret")
      on_exit(fn -> System.delete_env("AIUR_TEST_SECRET_1") end)

      assert EnvResolver.resolve_secret_setting("$AIUR_TEST_SECRET_1", nil) == "resolved-secret"
    end
  end

  describe "resolve_path_value/2" do
    test "returns the value when it is a plain non-empty path" do
      assert EnvResolver.resolve_path_value("/some/path", "/default") == "/some/path"
    end

    test "returns the default when the value is an empty string" do
      assert EnvResolver.resolve_path_value("", "/default") == "/default"
    end

    test "resolves $ENV_REF path tokens from the environment" do
      System.put_env("AIUR_TEST_PATH_VAR", "/resolved/path")
      on_exit(fn -> System.delete_env("AIUR_TEST_PATH_VAR") end)

      assert EnvResolver.resolve_path_value("$AIUR_TEST_PATH_VAR", "/default") == "/resolved/path"
    end

    test "returns the default when the $ENV_REF is missing" do
      System.delete_env("AIUR_TEST_PATH_MISSING")

      assert EnvResolver.resolve_path_value("$AIUR_TEST_PATH_MISSING", "/default") == "/default"
    end
  end
end
