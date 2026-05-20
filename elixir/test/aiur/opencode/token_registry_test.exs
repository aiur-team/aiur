defmodule Aiur.Opencode.TokenRegistryTest do
  use Aiur.TestSupport, async: false

  alias Aiur.Opencode.TokenRegistry

  test "validates token and identifier pairs" do
    refute TokenRegistry.valid?("token", "MT-1")

    assert :ok = TokenRegistry.put("token", "MT-1")
    assert TokenRegistry.valid?("token", "MT-1")
    refute TokenRegistry.valid?("token", "MT-2")
    refute TokenRegistry.valid?("other", "MT-1")

    assert :ok = TokenRegistry.delete("token", "MT-1")
    refute TokenRegistry.valid?("token", "MT-1")
  end
end
