defmodule Aiur.AlertFeedTest do
  use ExUnit.Case, async: true

  alias Aiur.AlertFeed

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-alert-feed-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "reads structured alert fields from persisted agent logs", %{root: root} do
    log = Path.join(root, "repo/42/logs/agent.ndjson")
    File.mkdir_p!(Path.dirname(log))

    File.write!(log, """
    {"event":"alert","timestamp":"2026-06-25T01:00:00Z","topic":"ticket.42.agent.paused","message":"Agent paused","reason":"operator paused the agent","severity":"warning","needs_attention":true,"source_ticket_id":"42"}
    {"event":"turn","topic":"ticket.42.turn.started"}
    """)

    assert [
             %{
               "source_ticket_id" => "42",
               "ticket" => "42",
               "agent" => "42",
               "topic" => "ticket.42.agent.paused",
               "reason" => "operator paused the agent",
               "severity" => "warning",
               "needs_attention" => true
             }
           ] = AlertFeed.list(roots: [root], log_roots: [])
  end

  test "needs-attention filtering only trusts emitted boolean fields", %{root: root} do
    log = Path.join(root, "repo/38/logs/agent.ndjson")
    File.mkdir_p!(Path.dirname(log))

    File.write!(log, """
    {"event":"alert","timestamp":"2026-06-25T01:00:00Z","name":"ticket.38.agent.paused","message":"legacy paused"}
    {"event":"alert","timestamp":"2026-06-25T01:01:00Z","name":"ticket.38.agent.tokens_exhausted","message":"tokens","needs_attention":true}
    """)

    assert [
             %{
               "topic" => "ticket.38.agent.tokens_exhausted",
               "needs_attention" => true
             }
           ] = AlertFeed.list(roots: [root], log_roots: [], needs_attention: true)
  end

  test "reads central alert feed entries", %{root: root} do
    log_root = Path.join(root, "logs")
    File.mkdir_p!(log_root)

    File.write!(Path.join(log_root, "alerts.ndjson"), """
    {"event":"alert","timestamp":"2026-06-25T01:02:00Z","topic":"system.github.connectivity_lost","message":"GitHub connectivity lost","reason":"GitHub API failed","severity":"warning","needs_attention":true,"source_ticket_id":null}
    """)

    assert [
             %{
               "agent" => "system",
               "topic" => "system.github.connectivity_lost",
               "reason" => "GitHub API failed",
               "severity" => "warning",
               "needs_attention" => true
             }
           ] = AlertFeed.list(roots: [root], log_roots: [log_root], needs_attention: true)
  end

  test "collapses repeated open attentions for one ticket and slug to the latest projection", %{root: root} do
    log_root = Path.join(root, "logs")
    File.mkdir_p!(log_root)

    File.write!(Path.join(log_root, "alerts.ndjson"), """
    {"event":"alert","timestamp":"2026-06-25T01:00:00Z","topic":"ticket.42.agent.attention.decision-delivery-act-1","message":"first failure","needs_attention":true,"source_ticket_id":"42"}
    {"event":"alert","timestamp":"2026-06-25T01:01:00Z","topic":"ticket.42.agent.attention.decision-delivery-act-1","message":"restart projection","needs_attention":true,"source_ticket_id":"42"}
    {"event":"alert","timestamp":"2026-06-25T01:02:00Z","topic":"ticket.42.agent.attention.other","message":"other attention","needs_attention":true,"source_ticket_id":"42"}
    """)

    alerts = AlertFeed.list(roots: [], log_roots: [log_root], needs_attention: true)

    assert Enum.map(alerts, & &1["message"]) == ["restart projection", "other attention"]
  end
end
