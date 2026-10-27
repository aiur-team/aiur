defmodule Aiur.CommandsCLIObservationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  alias Aiur.CommandsCLI.{Observation, Printer}

  test "partial, stale and unavailable observations never claim fresh data" do
    now = DateTime.utc_now()
    row = %{created_at: DateTime.add(now, -120), human_visible_at: nil}

    for source <- [%{health: %{status: :partial}}, %{health: %{status: :available, stale: true}}, %{health: %{status: :available}, partial_results?: true}] do
      observed = Observation.row(row, source, now)
      assert observed.freshness == :partial
      assert observed.age_ms == 120_000
      assert observed.needs_you_ms == nil
    end

    assert Observation.row(row, %{health: %{status: :unavailable}}, now).freshness == :unavailable
  end

  test "partial empty page renders a footer" do
    envelope = %{"snapshot" => %{"captured_at" => "now"}, "sources" => %{}, "data" => %{"page" => %{"decisions" => [], "partial_results?" => true}, "selected" => nil}}
    output = capture_io(fn -> Printer.print_human(envelope) end)
    assert output =~ "Partial retained data; results may be incomplete or stale."
  end

  test "rows render route, latest escalation, short label, requester and human-visible age" do
    row = %{
      "decision_id" => "cmd-1",
      "route_state" => "with_human",
      "age_ms" => 120_000,
      "needs_you_ms" => 30_000,
      "short_label" => "Approve release",
      "requester" => %{"kind" => "executor"},
      "escalations" => [%{"cause" => "executor_ack_timeout"}, %{"cause" => "executor_answer_timeout"}],
      "freshness" => "fresh",
      "observed_at" => "now"
    }

    envelope = %{"snapshot" => %{"captured_at" => "now"}, "sources" => %{}, "data" => %{"page" => %{"decisions" => [row]}, "selected" => nil}}
    output = capture_io(fn -> Printer.print_human(envelope) end)
    assert output =~ "cmd-1  Needs you  120s  executor_answer_timeout  Approve release  Executor"
    assert output =~ "Needs you since: 30s ago"
  end
end
