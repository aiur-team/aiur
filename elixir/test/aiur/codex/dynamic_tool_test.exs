defmodule Aiur.Codex.DynamicToolTest do
  use ExUnit.Case, async: false

  alias Aiur.Codex.DynamicTool

  @emit_event_tool "emit_event"

  setup do
    DynamicTool.reset_turn_quotas()
    :ok
  end

  describe "execute/3 emit_event — bare `progress` allowlist + per-turn cap" do
    test "bare `progress` is accepted and published" do
      {captured, publisher} = capture_publisher()

      response =
        DynamicTool.execute(
          @emit_event_tool,
          emit_args("progress", "starting work", %{"percent" => 30, "label" => "work: typing"}),
          event_publisher: publisher
        )

      assert success?(response)
      assert [{"progress", "starting work", %{"percent" => 30, "label" => "work: typing"}}] = capture_take(captured)
    end

    test "2 progress emits in the same turn both succeed" do
      {captured, publisher} = capture_publisher()
      opts = [event_publisher: publisher]

      assert success?(DynamicTool.execute(@emit_event_tool, emit_args("progress", "30%", %{"percent" => 30}), opts))
      assert success?(DynamicTool.execute(@emit_event_tool, emit_args("progress", "60%", %{"percent" => 60}), opts))

      assert length(capture_take(captured)) == 2
    end

    test "3rd progress emit in the same turn is rejected and not published" do
      {captured, publisher} = capture_publisher()
      opts = [event_publisher: publisher]

      assert success?(DynamicTool.execute(@emit_event_tool, emit_args("progress", "30%", %{"percent" => 30}), opts))
      assert success?(DynamicTool.execute(@emit_event_tool, emit_args("progress", "60%", %{"percent" => 60}), opts))

      response = DynamicTool.execute(@emit_event_tool, emit_args("progress", "100%", %{"percent" => 100}), opts)

      refute success?(response)
      assert error_message(response) =~ "per-turn `progress` cap"
      assert length(capture_take(captured)) == 2
    end

    test "cap resets on a new turn — 2 emits in turn-1 + 2 emits in turn-2 all succeed" do
      {captured, publisher} = capture_publisher()
      opts = [event_publisher: publisher]

      # turn 1: 2 emits
      assert success?(DynamicTool.execute(@emit_event_tool, emit_args("progress", "30%", %{"percent" => 30}), opts))
      assert success?(DynamicTool.execute(@emit_event_tool, emit_args("progress", "60%", %{"percent" => 60}), opts))

      # turn boundary
      assert :ok = DynamicTool.reset_turn_quotas()

      # turn 2: 2 more emits
      assert success?(DynamicTool.execute(@emit_event_tool, emit_args("progress", "80%", %{"percent" => 80}), opts))
      assert success?(DynamicTool.execute(@emit_event_tool, emit_args("progress", "100%", %{"percent" => 100}), opts))

      assert length(capture_take(captured)) == 4
    end

    test "progress and custom share NO budget — 2 progress emits + several custom emits all succeed" do
      {captured, publisher} = capture_publisher()
      opts = [event_publisher: publisher]

      assert success?(DynamicTool.execute(@emit_event_tool, emit_args("progress", "30%", %{"percent" => 30}), opts))
      assert success?(DynamicTool.execute(@emit_event_tool, emit_args("progress", "60%", %{"percent" => 60}), opts))

      for slug <- ["heartbeat", "ping", "pong"] do
        name = "custom.#{slug}"
        assert success?(DynamicTool.execute(@emit_event_tool, emit_args(name, slug, %{}), opts))
      end

      # 2 progress + 3 custom = 5 published
      assert length(capture_take(captured)) == 5
    end

    test "`progress.<slug>` (existing milestone vocab) still works and is not counted against the progress cap" do
      {captured, publisher} = capture_publisher()
      opts = [event_publisher: publisher]

      # Exhaust the bare-progress quota
      assert success?(DynamicTool.execute(@emit_event_tool, emit_args("progress", "30%", %{"percent" => 30}), opts))
      assert success?(DynamicTool.execute(@emit_event_tool, emit_args("progress", "60%", %{"percent" => 60}), opts))

      # `progress.<slug>` milestone events still publish freely
      assert success?(DynamicTool.execute(@emit_event_tool, emit_args("progress.tests-green", "tests pass", %{}), opts))
      assert success?(DynamicTool.execute(@emit_event_tool, emit_args("progress.compile-clean", "compile clean", %{}), opts))

      assert length(capture_take(captured)) == 4
    end
  end

  # ---- helpers ----

  defp emit_args(name, message, payload),
    do: %{"name" => name, "message" => message, "payload" => payload}

  defp capture_publisher do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    publisher = fn name, message, payload ->
      Agent.update(agent, fn calls -> [{name, message, payload} | calls] end)
      {:ok, %{"published" => true}}
    end

    {agent, publisher}
  end

  defp capture_take(agent) do
    Agent.get(agent, fn calls -> Enum.reverse(calls) end)
  end

  defp success?(%{"success" => true}), do: true
  defp success?(%{success: true}), do: true
  defp success?(_), do: false

  defp error_message(response) do
    response
    |> Map.get("output", response[:output] || "")
    |> case do
      output when is_binary(output) -> output
      _ -> ""
    end
  end
end
