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

  test "missing or unrecognized source health is unavailable" do
    now = DateTime.utc_now()
    row = %{created_at: DateTime.add(now, -120)}

    for source <- [%{}, %{health: %{}}, %{health: %{status: :unknown}}] do
      observed = Observation.row(row, source, now)
      assert observed.freshness == :unavailable
      assert observed.age_ms == 120_000
    end
  end

  test "simultaneous routing uses the dashboard label in rows and detail" do
    row = %{"decision_id" => "cmd-both", "route_state" => "with_both", "question" => "Approve release?", "escalations" => []}

    for selected <- [nil, row] do
      output = capture_io(fn -> Printer.print_human(envelope(row, selected)) end)
      assert output =~ "Needs you and Executor"
    end
  end

  test "unknown escalation data is distinct from an empty history in rows and detail" do
    row = %{"decision_id" => "cmd-why", "question" => "Approve release?", "age_ms" => 0}

    for escalations <- [:missing, nil, "invalid", %{}, [%{}], [nil], [%{"cause" => nil}], [%{"cause" => ""}], [%{"cause" => 123}]] do
      row = if escalations == :missing, do: row, else: Map.put(row, "escalations", escalations)
      output = capture_io(fn -> Printer.print_human(envelope(row)) end)
      assert output =~ "cmd-why  ?  0s  ?  Approve release?"
      output = capture_io(fn -> Printer.print_human(envelope(row, row)) end)
      assert output =~ "Why: ?"
    end

    row = Map.put(row, "escalations", [])
    assert capture_io(fn -> Printer.print_human(envelope(row)) end) =~ "cmd-why  ?  0s  -  Approve release?"
    assert capture_io(fn -> Printer.print_human(envelope(row, row)) end) =~ "Why: -"
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

  defp envelope(row, selected \\ nil) do
    %{"snapshot" => %{"captured_at" => "now"}, "sources" => %{}, "data" => %{"page" => %{"decisions" => [row]}, "selected" => selected}}
  end
end
