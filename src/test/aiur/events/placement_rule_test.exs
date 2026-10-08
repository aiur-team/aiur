defmodule Aiur.Events.PlacementRuleTest do
  @moduledoc """
  Source guards for placement rule R-4 and frozen topic grammar §9.

  Interpolated and runtime topics belong to C5-T01's catalog census. This
  scan recognizes the named publishing APIs and PubSub wrappers below;
  update the wrapper list when C2-T05 changes the trace sink.
  """
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib", __DIR__)
  @known_violations [
    {"aiur/decision_store.ex", "decision_store.unrecognized_event_types"},
    {"aiur/decision_store.ex", "decision_store.corrupted"},
    {"aiur/decision_store.ex", "decision_store.repair_failed"},
    {"aiur/decision_store.ex", "decision_store.append_ambiguous"},
    {"aiur/executor_events.ex", "executor_events.corrupted"},
    {"aiur/github/dispatch_authorization.ex", "github.dispatch_authorization.ambiguous"},
    {"aiur/github/dispatch_authorization.ex", "github.dispatch_authorization.timeline_unreadable"},
    {"aiur/orchestrator/retry_engine.ex", "orchestrator.claim_released"}
  ]
  @bridges ["aiur/ticket_activity.ex", "aiur/build_order/ticket_history_provider.ex", "aiur/decision_metrics.ex"]
  @reverse_bridges []
  @topic_calls ~r/\b(?:emit_custom|emit_system|Publisher\.publish(?:_persisted)?|ExecutorEvents\.publish|Exchange\.publish)\(\s*"([^"#]*)"/s
  @exchange_subscriber ~r/\bExchange\.subscribe\s*(?:\(|\/)|\bexchange_subscribe_fun\b/
  @pubsub_broadcaster ~r/\b(?:Phoenix\.PubSub\.(?:local_)?broadcast!?|DecisionPubSub\.broadcast_(?:changed|metrics_changed)|ObservabilityPubSub\.broadcast_update|AgentPubSub\.broadcast)\s*(?:\(|\/)/
  @pubsub_subscriber ~r/\bPhoenix\.PubSub\.subscribe\s*(?:\(|\/)/
  @exchange_publisher ~r/\b(?:Publisher\.publish(?:_persisted)?|ExecutorEvents\.publish|Exchange\.publish)\s*(?:\(|\/)/

  setup_all do
    %{sources: source_files()}
  end

  test "every literal Exchange topic follows the ticket/system/executor grammar except the recorded violations", %{sources: sources} do
    for {file, source} <- sources, {topic, line} <- topics(source) do
      assert Regex.match?(~r/^(ticket|system|executor)\./, topic) or {file, topic} in @known_violations,
             "§9: #{file}:#{line} publishes non-conforming topic #{inspect(topic)}"
    end
  end

  test "recorded grammar violations still exist (ratchet only shrinks)", %{sources: sources} do
    for {file, topic} <- @known_violations do
      source = Map.fetch!(sources, file)

      assert Enum.any?(topics(source), fn {found, _line} -> found == topic end),
             "§9: #{file}:1 no longer publishes #{inspect(topic)}; remove its recorded exception"
    end
  end

  test "only the three recorded bridges subscribe to the Exchange and broadcast PubSub", %{sources: sources} do
    for {file, source} <- sources do
      if Regex.match?(@exchange_subscriber, source) and Regex.match?(@pubsub_broadcaster, source) do
        assert file in @bridges, "R-4: #{file}:#{match_line(source, @pubsub_broadcaster)} bridges Exchange to PubSub"
      end
    end
  end

  test "no module bridges PubSub back into the Exchange", %{sources: sources} do
    for {file, source} <- sources do
      if Regex.match?(@pubsub_subscriber, source) and Regex.match?(@exchange_publisher, source) do
        assert file in @reverse_bridges, "R-4: #{file}:#{match_line(source, @exchange_publisher)} bridges PubSub to Exchange"
      end
    end
  end

  test "scanner ignores docs and comments while preserving multiline calls, hashes, and source lines" do
    source = ~S'''
    @moduledoc """
    Alerts.emit_custom("doc.topic", "x")
    """
    @doc "Exchange.publish(\"doc.topic\", %{})"
    # Alerts.emit_custom("comment.topic", "x")
    Alerts.emit_custom(
      "orphan.topic", "hash # inside a string") # trailing comment
    Publisher.publish("ticket.1.valid", %{})
    Alerts.emit_custom("ticket.#{id}.dynamic", "x")
    '''

    stripped = strip_docs(source)
    assert topics(stripped) == [{"orphan.topic", 6}, {"ticket.1.valid", 8}]
    assert stripped =~ "hash # inside a string"
    refute stripped =~ "doc.topic"
    refute stripped =~ "comment.topic"
  end

  defp source_files do
    files = Path.wildcard(Path.join(@lib_root, "**/*.ex"))
    assert files != [], "Placement census found no lib/**/*.ex files"
    Map.new(files, fn path -> {Path.relative_to(path, @lib_root), path |> File.read!() |> strip_docs()} end)
  end

  defp strip_docs(source) do
    # Keep string tokens intact so a hash inside a string is never a comment.
    tokens = ~r/@(?:moduledoc|doc)\s+(?:~[sS])?(?:""".*?"""|"(?:\\.|[^"\\])*")|""".*?"""|"(?:\\.|[^"\\])*"|\#[^\n]*/s

    Regex.replace(tokens, source, fn token ->
      if String.starts_with?(token, ["@moduledoc", "@doc", "#"]), do: Regex.replace(~r/[^\n]/, token, " "), else: token
    end)
  end

  defp topics(source) do
    Enum.map(Regex.scan(@topic_calls, source, return: :index), fn [{offset, _length}, {start, length}] ->
      {binary_part(source, start, length), line_at(source, offset)}
    end)
  end

  defp match_line(source, pattern) do
    [{offset, _length}] = Regex.run(pattern, source, return: :index)
    line_at(source, offset)
  end

  defp line_at(source, offset), do: source |> binary_part(0, offset) |> String.split("\n") |> length()
end
