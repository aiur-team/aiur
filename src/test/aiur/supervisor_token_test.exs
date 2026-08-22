defmodule Aiur.SupervisorTokenTest do
  use ExUnit.Case, async: true

  alias Aiur.SupervisorToken

  @valid_token String.duplicate("a", 32)

  test "classifies an absent token separately from invalid configured values" do
    assert SupervisorToken.classify(nil) == :missing

    for token <- ["", "   ", String.duplicate("a", 31), " " <> @valid_token, @valid_token <> " ", String.duplicate(":", 32)] do
      assert SupervisorToken.classify(token) == :invalid
    end
  end

  test "accepts bearer-safe tokens of at least 32 bytes" do
    assert SupervisorToken.classify(@valid_token) == {:ok, @valid_token}
    assert SupervisorToken.classify("abcdEFGH0123-._~+/abcdEFGH0123-._~+/==") == {:ok, "abcdEFGH0123-._~+/abcdEFGH0123-._~+/=="}
  end
end
