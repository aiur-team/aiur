defmodule Aiur.TestSupportLoadingTest do
  use ExUnit.Case, async: true

  @support Path.expand("support", __DIR__)
  @helper File.read!(Path.expand("test_helper.exs", __DIR__))

  test "test_helper loads every support file by convention" do
    files = Path.wildcard(Path.join(@support, "**/*.{ex,exs}"))

    assert files != []
    assert files -- Code.required_files() == []
  end

  # A support file earns an explicit line only when it must load before the
  # sorted glob reaches it. Growing this list brings back the append conflict (#4219).
  test "the explicit load-first list does not grow" do
    listed = Regex.scan(~r/require_file\("([^"]+)"/, @helper, capture: :all_but_first)

    assert List.flatten(listed) == [
             "support/test_boot_guard.exs",
             "support/test_tmp.exs",
             "support/test_support.exs",
             "support/event_ticket.ex"
           ]
  end
end
