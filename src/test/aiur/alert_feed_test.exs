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
           ] = AlertFeed.list(roots: [root])
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
           ] = AlertFeed.list(roots: [root], needs_attention: true)
  end
end
