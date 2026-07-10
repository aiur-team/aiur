defmodule Aiur.Codex.DynamicTool.HandlerTest do
  use ExUnit.Case, async: true

  alias Aiur.Codex.DynamicTool.Blockers
  alias Aiur.Codex.DynamicTool.EmitAlert
  alias Aiur.Codex.DynamicTool.EmitEvent
  alias Aiur.Codex.DynamicTool.LinearGraphQL
  alias Aiur.Codex.DynamicTool.ReviewThreads
  alias Aiur.Codex.DynamicTool.Subscriptions

  @handlers [LinearGraphQL, ReviewThreads, EmitAlert, EmitEvent, Subscriptions, Blockers]

  for mod <- [LinearGraphQL, ReviewThreads, EmitAlert, EmitEvent, Subscriptions, Blockers] do
    describe "#{mod}" do
      test "tools/0 returns a non-empty list of strings" do
        tools = unquote(mod).tools()
        assert is_list(tools)
        assert tools != []
        assert Enum.all?(tools, &is_binary/1)
      end

      test "specs/0 returns one map per tool name" do
        tools = unquote(mod).tools()
        specs = unquote(mod).specs()

        assert length(specs) == length(tools)

        for spec <- specs do
          assert is_map(spec)
          assert Map.has_key?(spec, "name")
          assert Map.has_key?(spec, "description")
          assert Map.has_key?(spec, "inputSchema")
          assert spec["name"] in tools
        end
      end

      test "each spec name appears in tools/0" do
        tools = unquote(mod).tools()

        for spec <- unquote(mod).specs() do
          assert spec["name"] in tools
        end
      end
    end
  end

  test "all handlers together cover the 9 expected tool names" do
    all_tools = Enum.flat_map(@handlers, & &1.tools())

    expected = [
      "linear_graphql",
      "aiur_reply_review_thread",
      "aiur_resolve_review_thread",
      "emit_alert",
      "emit_event",
      "aiur_subscribe",
      "aiur_unsubscribe",
      "aiur_declare_blocker",
      "aiur_unblock"
    ]

    assert Enum.sort(all_tools) == Enum.sort(expected)
  end
end
