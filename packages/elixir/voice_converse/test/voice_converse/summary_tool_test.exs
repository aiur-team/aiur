defmodule VoiceConverse.SummaryToolTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.{Config, Events, SummaryTool, Tools}

  defp state(allowed \\ ["record_summary"]) do
    %{
      id: "summary-session",
      config: %Config{allowed_tools: allowed},
      subscribers: %{self() => make_ref()},
      event_broadcast: fn subscribers, id, event ->
        Enum.each(Map.keys(subscribers), &send(&1, {:voice_conversation, id, event}))
      end
    }
  end

  defp params do
    %{
      "decisions" => ["Ship the approved release"],
      "open_questions" => ["Who will deploy?"],
      "ideas" => ["Maybe add a health panel"]
    }
  end

  defp fallback(_state, _event), do: raise("record_summary must use its validated handler")

  test "record_summary preserves decision, question and idea categories in a validated event" do
    state = state()
    [spec] = Tools.specs(state.config, :executor)
    assert spec.name == "record_summary"
    assert Enum.sort(spec.parameters["required"]) == ["decisions", "ideas", "open_questions"]
    assert spec.parameters["additionalProperties"] == false
    assert spec.parameters["properties"]["decisions"]["type"] == "array"
    assert spec.parameters["properties"]["open_questions"]["items"]["type"] == "string"
    assert spec.parameters["properties"]["ideas"]["items"]["type"] == "string"
    event = %Events.ToolCall{call_id: "summary", name: "record_summary", params: params()}
    assert {%{is_error: false, end?: false}, ^state} = Tools.dispatch(state, event, &fallback/2)

    assert_received {:voice_conversation, "summary-session",
                     {:summary_recorded,
                      %{
                        decisions: ["Ship the approved release"],
                        open_questions: ["Who will deploy?"],
                        ideas: ["Maybe add a health panel"]
                      }}}
  end

  test "invalid summary shapes produce an error and no recorded summary" do
    invalid = [
      Map.delete(params(), "ideas"),
      Map.put(params(), "extra", []),
      Map.put(params(), "decisions", "yes"),
      Map.put(params(), "ideas", [""]),
      Map.put(params(), "ideas", [7]),
      Map.put(params(), "ideas", List.duplicate("idea", 21)),
      Map.put(params(), "ideas", [String.duplicate("x", 501)])
    ]

    for params <- invalid do
      event = %Events.ToolCall{call_id: "invalid", name: "record_summary", params: params}
      assert {%{is_error: true, end?: false}, _state} = Tools.dispatch(state(), event, &fallback/2)
      refute_received {:voice_conversation, "summary-session", {:summary_recorded, _}}
    end
  end

  test "the host allowlist blocks summary recording before any event is emitted" do
    event = %Events.ToolCall{call_id: "blocked", name: "record_summary", params: params()}
    assert {%{is_error: true}, _state} = Tools.dispatch(state(["get_status"]), event, &fallback/2)
    refute_received {:voice_conversation, "summary-session", {:summary_recorded, _}}
  end

  test "summary text is redacted before broadcast and before transcript persistence" do
    params = Map.put(params(), "ideas", ["Use Bearer abcdefgh12345"])
    event = %Events.ToolCall{call_id: "secret", name: "record_summary", params: params}
    state = state()
    assert {%{is_error: false}, _state} = Tools.dispatch(state, event, &fallback/2)
    assert_received {:voice_conversation, "summary-session", {:summary_recorded, %{ideas: ["Use [redacted]"]}}}
    assert SummaryTool.redact_event(state.config, event).params["ideas"] == ["Use [redacted]"]
  end
end
