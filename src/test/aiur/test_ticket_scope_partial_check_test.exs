defmodule Aiur.TestTicketScopePartialCheckTest do
  use ExUnit.Case, async: true

  # A test that puts AIUR_DEV_TEST_TICKET_IDS without the rest of the launcher's
  # scope leaves Ownership.Store unable to restart after any child crash (#4736).
  @partial_scope ~r/put_env\(\s*"AIUR_DEV_TEST_TICKET_IDS"/
  @helper "test/support/test_scope_guard.exs"

  test "tests set the ticket scope only through Aiur.TestScopeGuard.put_ticket_scope!/1" do
    offenders =
      for path <- Path.wildcard("test/**/*.{ex,exs}"),
          path not in [@helper, "test/aiur/test_ticket_scope_partial_check_test.exs"],
          {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(@partial_scope, line),
          do: "#{path}:#{number}"

    assert offenders == [], "use Aiur.TestScopeGuard.put_ticket_scope!/1 instead: #{Enum.join(offenders, ", ")}"
  end

  test "the pattern catches a direct scope put" do
    assert Regex.match?(@partial_scope, ~S|System.put_env("AIUR_DEV_TEST_TICKET_IDS", "99")|)
    refute Regex.match?(@partial_scope, ~S|System.delete_env("AIUR_DEV_TEST_TICKET_IDS")|)
  end
end
