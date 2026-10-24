defmodule Aiur.Events.GithubCIPoller.CancelledRunTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.GithubCIPoller.CancelledRun

  test "recognizes gate-only failures and superseded runs, but preserves real upstream failures" do
    gate_failure = [
      %{"name" => "test", "conclusion" => "cancelled"},
      %{"name" => "lint", "conclusion" => "cancelled"},
      %{"name" => "ci gate", "conclusion" => "failure"}
    ]

    assert CancelledRun.cancelled?(%{"event" => "merge_group", "conclusion" => "failure"}, gate_failure)
    assert CancelledRun.cancelled?(%{"event" => "pull_request"}, gate_failure)

    superseded = Enum.map(gate_failure, &Map.put(&1, "conclusion", "cancelled"))
    assert CancelledRun.cancelled?(%{"event" => "merge_group", "conclusion" => "cancelled"}, superseded)

    mixed = List.replace_at(gate_failure, 1, %{"name" => "lint", "conclusion" => "failure"})
    refute CancelledRun.cancelled?(%{"event" => "merge_group", "conclusion" => "failure"}, mixed)
  end
end
