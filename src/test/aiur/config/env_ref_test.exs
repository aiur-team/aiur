defmodule Aiur.Config.EnvRefTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.EnvRef

  @env_var "AIUR_ENV_REF_TEST_VAR"

  setup do
    System.delete_env(@env_var)
    on_exit(fn -> System.delete_env(@env_var) end)
    :ok
  end

  describe "resolve/2" do
    test "nil value resolves to the fallback" do
      assert EnvRef.resolve(nil, "fallback-secret") == "fallback-secret"
    end

    test "nil value with blank or nil fallback resolves to nil" do
      assert EnvRef.resolve(nil, "") == nil
      assert EnvRef.resolve(nil, nil) == nil
    end

    test "$VAR resolves the referenced env var" do
      System.put_env(@env_var, "from-env")
      assert EnvRef.resolve("$#{@env_var}", "fallback") == "from-env"
    end

    test "$VAR with the var missing falls back" do
      assert EnvRef.resolve("$#{@env_var}", "fallback") == "fallback"
    end

    test "$VAR with the var set to empty string is missing, not fallback" do
      System.put_env(@env_var, "")
      assert EnvRef.resolve("$#{@env_var}", "fallback") == nil
    end

    test "non-reference values pass through as literals" do
      assert EnvRef.resolve("literal-secret", "fallback") == "literal-secret"
    end

    test "empty literal normalizes to nil" do
      assert EnvRef.resolve("", "fallback") == nil
    end

    test "legacy env: references stay literal" do
      assert EnvRef.resolve("env:#{@env_var}", "fallback") == "env:#{@env_var}"
    end

    test "$ followed by an invalid identifier stays literal" do
      assert EnvRef.resolve("$not-a-var", "fallback") == "$not-a-var"
    end
  end

  describe "reference_name/1" do
    test "valid identifiers after $ are references" do
      assert EnvRef.reference_name("$MY_VAR") == {:ok, "MY_VAR"}
      assert EnvRef.reference_name("$_private1") == {:ok, "_private1"}
    end

    test "invalid identifiers and non-references are :error" do
      assert EnvRef.reference_name("$1BAD") == :error
      assert EnvRef.reference_name("$has-dash") == :error
      assert EnvRef.reference_name("plain") == :error
      assert EnvRef.reference_name(nil) == :error
    end
  end

  describe "normalize_secret/1" do
    test "trims binaries and blanks become nil" do
      assert EnvRef.normalize_secret("  token  ") == "token"
      assert EnvRef.normalize_secret("   ") == nil
      assert EnvRef.normalize_secret("") == nil
    end

    test "non-binaries become nil" do
      assert EnvRef.normalize_secret(nil) == nil
      assert EnvRef.normalize_secret(123) == nil
    end
  end
end
