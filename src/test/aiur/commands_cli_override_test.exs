defmodule Aiur.CommandsCLIOverrideTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Aiur.CommandsCLI.Printer

  test "table and selected detail include override state and Command, ticket and PR links" do
    row = %{
      "decision_id" => "cmd-cli",
      "question" => "Ship?",
      "overrides" => [%{"state" => "queued", "route" => "capacity_wait", "ticket" => %{"identifier" => "42", "url" => "https://github.com/o/r/issues/42"}, "pr_number" => 71}]
    }

    for selected <- [nil, row] do
      envelope = %{"snapshot" => %{"captured_at" => "now"}, "sources" => %{}, "data" => %{"page" => %{"decisions" => [row]}, "selected" => selected}}
      output = capture_io(fn -> Printer.print_human(envelope) end)
      if is_nil(selected), do: assert(output =~ "ID  ROUTE  AGE  WHY  ASKS  TICKET|EXECUTOR  OVERRIDE")
      assert output =~ "Queued — waiting for a slot · Original Command: /commands/cmd-cli · Ticket #42: https://github.com/o/r/issues/42 · PR #71: https://github.com/o/r/pull/71"
    end
  end
end
