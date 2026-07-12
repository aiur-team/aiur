defmodule Aiur.ConfigTest do
  use ExUnit.Case, async: true

  alias Aiur.Config

  describe "rate_limit_fallback_backend/0" do
    test "defaults to claude" do
      assert Config.rate_limit_fallback_backend() == "claude"
    end
  end
end
