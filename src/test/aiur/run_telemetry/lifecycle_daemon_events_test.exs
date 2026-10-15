defmodule Aiur.RunTelemetry.LifecycleDaemonEventsTest do
  use ExUnit.Case, async: true

  alias Aiur.RunTelemetry.Lifecycle

  test "ci.failed gives a ci_result with outcome, pr and short sha, and no failure excerpt" do
    event = %{
      id: 5,
      topic: "ticket.42.ci.failed",
      source: :github,
      head_sha: "0123456789abcdef0123456789abcdef01234567",
      pr_number: 77,
      failure_excerpt: "secret stack trace",
      timestamp: "2026-07-11T13:00:00Z"
    }

    assert {:ok, attributes, "2026-07-11T13:00:00Z"} = Lifecycle.external_anchor(event)
    assert %{event: "ci_result", boundary: "point", ticket: "42", outcome: "failed", pr_number: 77} = attributes
    assert attributes.head_sha == "0123456789ab"
    refute inspect(attributes) =~ "secret"
  end

  test "ci.passed gives outcome passed" do
    event = %{id: 6, topic: "ticket.42.ci.passed", source: :github, head_sha: "abc", pr_number: 77}

    assert {:ok, %{event: "ci_result", outcome: "passed"}, _timestamp} = Lifecycle.external_anchor(event)
  end

  test "pr.ready_for_review gives a pr_ready point at the event timestamp" do
    event = %{id: 7, topic: "ticket.42.pr.ready_for_review", source: :github, pr: %{"number" => 77}, timestamp: "2026-07-11T14:00:00Z"}

    assert {:ok, attributes, "2026-07-11T14:00:00Z"} = Lifecycle.external_anchor(event)
    assert %{event: "pr_ready", ticket: "42", pr_number: 77} = attributes
  end

  # Future-regression guard: unknown topics were already rejected before daemon metrics.
  test "an unknown topic is still skipped" do
    assert :skip = Lifecycle.external_anchor(%{id: 8, topic: "ticket.42.ci.pending", source: :github})
  end
end
