defmodule Aiur.Codex.ConfigTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.Config
  alias Aiur.Config.Schema

  @valid ~w(untrusted on-failure on-request granular never)

  describe "approval_policy default" do
    test "the codex schema defaults approval_policy to a valid codex variant, not a map" do
      # codex app-server expects approvalPolicy to be one of the enum variants;
      # the old map default (`%{"reject" => ...}`) crashed the turn with
      # `unknown variant`. The default must stay a non-`never` variant so it
      # preserves fail-closed behavior.
      default = %Schema.Codex{}.approval_policy

      assert is_binary(default), "expected a variant string, got: #{inspect(default)}"
      assert default in @valid
    end
  end

  describe "validate_approval_policy/1" do
    test "accepts every codex variant" do
      for variant <- @valid do
        assert {:ok, ^variant} = Config.validate_approval_policy(variant)
      end
    end

    test "trims surrounding whitespace" do
      assert {:ok, "never"} = Config.validate_approval_policy("  never  ")
    end

    test "rejects an unknown string with a message listing the variants" do
      assert {:error, message} = Config.validate_approval_policy("banana")
      assert message =~ "never"
      assert message =~ "untrusted"
    end

    test "rejects the legacy reject-map shape" do
      assert {:error, _} =
               Config.validate_approval_policy(%{"reject" => %{"rules" => true}})
    end
  end
end
