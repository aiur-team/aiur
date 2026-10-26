defmodule Aiur.Events.CatalogCensusTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.Catalog

  @lib_root Path.expand("../../../lib", __DIR__)
  @legacy_prefixes ~w(decision_store. executor_events. github.dispatch_authorization. orchestrator.claim_released compaction. config.override_rejected)
  @finite_topics %{
    "ticket.*.ci.*" => ~w(ticket.*.ci.passed ticket.*.ci.failed),
    "ticket.*.queue.*" => Enum.map(~w(promoted withdrawn held released overridden removed), &"ticket.*.queue.#{&1}"),
    "system.*.*.progress" => ~w(system.queue.*.progress system.build_order.*.progress)
  }

  test "every producer topic literal has an explicit catalog entry" do
    patterns = MapSet.new(Catalog.entries(), & &1.pattern)
    files = Path.wildcard(Path.join(@lib_root, "**/*.ex")) |> Enum.reject(&String.contains?(&1, "/events/catalog"))
    assert length(files) > 100

    missing =
      for file <- files,
          topic <- topics(File.read!(file)),
          expanded <- Map.get(@finite_topics, topic, [topic]),
          not MapSet.member?(patterns, registered_pattern(expanded)) or Catalog.lookup(String.replace(expanded, "*", "census")).owner == "unknown" do
        "#{Path.relative_to(file, @lib_root)}: #{expanded}"
      end

    assert missing == [], "Producer topics without catalog entries:\n" <> Enum.join(missing, "\n")
  end

  test "census ignores documentation, comments, subscriptions, paths and topic prefixes" do
    source = ~S'''
    @moduledoc "Events.publish(\"system.docs.fake\", %{})"
    @doc """
    Events.publish("ticket.1.doc.fake", %{})
    """
    # Signal.alert("system.comment.fake", [])
    Events.subscribe("ticket.*.future.reserved")
    @path "executor.events.ndjson"
    String.starts_with?(topic, "ticket.")
    Events.publish("ticket.#{ticket}.ci.#{outcome}", %{})
    Signal.alert("ticket.#{ticket}.agent.attention.delivery-#{id}", [])
    Events.publish("system.capabilities.changed", %{})
    '''

    assert topics(source) == ["ticket.*.ci.*", "ticket.*.agent.attention.*", "system.capabilities.changed"]
  end

  # Parse literals rather than scanning interpolations with a regex: nested
  # expressions and hashes inside strings remain intact. Docs are pruned just
  # like PlacementRuleTest's source scan; the parser already discards comments.
  defp topics(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk(fn
      {:@, _, [{name, _, _}]} when name in [:moduledoc, :doc] -> nil
      node -> node
    end)
    |> Macro.prewalk([], &collect_topic/2)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp collect_topic({:<<>>, _, parts}, acc) do
    topic = Enum.map_join(parts, fn part -> if is_binary(part), do: part, else: "*" end)
    {nil, add_topic(topic, acc, true)}
  end

  defp collect_topic(topic, acc) when is_binary(topic), do: {topic, add_topic(topic, acc, false)}
  defp collect_topic(node, acc), do: {node, acc}

  defp add_topic(topic, acc, dynamic?) do
    if topic?(topic) and (dynamic? or not String.contains?(topic, ["*", "#"])) do
      normalized = topic |> String.split(".") |> Enum.map_join(".", fn segment -> if String.contains?(segment, "*"), do: "*", else: segment end)
      [normalized | acc]
    else
      acc
    end
  end

  defp topic?(topic) do
    String.starts_with?(topic, ["ticket.", "system.", "executor." | @legacy_prefixes]) and
      Regex.match?(~r/\A[a-z_]+(?:\.[a-zA-Z0-9_*#-]+)+\z/, topic) and
      not String.ends_with?(topic, [".json", ".ndjson"]) and
      complete_topic?(topic)
  end

  defp complete_topic?("ticket." <> rest), do: length(String.split(rest, ".")) >= 3
  defp complete_topic?("system." <> rest), do: length(String.split(rest, ".")) >= 2
  defp complete_topic?("executor." <> rest), do: length(String.split(rest, ".")) >= 2
  defp complete_topic?(_topic), do: true

  defp registered_pattern("ticket.*.agent.*"), do: "ticket.*.agent.#"
  defp registered_pattern("ticket.*.agent.decision." <> _), do: "ticket.*.agent.decision.#"
  defp registered_pattern("ticket.*.agent.attention.*"), do: "ticket.*.agent.attention.#"
  defp registered_pattern("executor.decision." <> _), do: "executor.#"
  defp registered_pattern("executor.command.*"), do: "executor.command.*"
  defp registered_pattern(topic), do: topic
end
