defmodule Aiur.GitHub.CIPollBatchTerminalTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.CIPollBatchTerminal

  test "prefers an open PR and returns a terminal PR when none remain open" do
    merged = %{"state" => "CLOSED", "mergedAt" => "2026-10-25T00:00:00Z"}
    closed = %{"state" => "CLOSED", "mergedAt" => nil}
    open = %{"state" => "OPEN", "mergedAt" => nil}

    assert {:terminal, ^merged} = CIPollBatchTerminal.select([%{"nodes" => [merged, closed]}])
    assert {:open, ^open} = CIPollBatchTerminal.select([%{"nodes" => [merged, open]}])
    assert :incomplete = CIPollBatchTerminal.select([%{"nodes" => [closed], "pageInfo" => %{"hasNextPage" => true}}])
  end
end
