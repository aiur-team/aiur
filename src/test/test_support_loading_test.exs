defmodule Aiur.TestSupportLoadingTest do
  use ExUnit.Case, async: true

  @support Path.expand("support", __DIR__)
  @helper File.read!(Path.expand("test_helper.exs", __DIR__))

  test "test_helper loads every support file by convention" do
    files = Path.wildcard(Path.join(@support, "**/*.{ex,exs}"))

    assert files != []
    assert files -- Code.required_files() == []
  end

  # Other support files import these two at compile time, so they must load before the
  # sorted glob. The stricter check, that the explicit list does not grow, returns with
  # the cleanup that deletes the list (#4219); until then open PRs still add lines.
  test "the glob loader follows the load-first files" do
    offset = fn text ->
      assert {at, _length} = :binary.match(@helper, text)
      at
    end

    glob = offset.(~s|Path.wildcard(Path.join(__DIR__, "support/**/*.{ex,exs}"))|)

    assert offset.(~s|require_file("support/test_support.exs"|) < glob
    assert offset.(~s|require_file("support/event_ticket.ex"|) < glob
  end
end
