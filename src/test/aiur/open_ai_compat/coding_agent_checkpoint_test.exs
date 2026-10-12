defmodule Aiur.OpenAICompat.CodingAgentCheckpointTest do
  use ExUnit.Case, async: true
  use Aiur.TestSupport.OpenAICompatAgent

  alias Aiur.OpenAICompat.CodingAgent

  test "a message delivered at the completion checkpoint receives a provider response", %{workspace: workspace} do
    parent = self()

    first =
      response(%{
        "id" => "completion-before-message",
        "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Initial response."}}]
      })

    followup =
      response(%{
        "id" => "completion-after-message",
        "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Operator message answered."}}]
      })

    {:ok, queue} = Agent.start_link(fn -> [first, followup] end)

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: queue_fun(queue, parent)
             )

    checkpoint = fn
      %{kind: :notification} ->
        if Process.get(:completion_message_delivered) do
          :noop
        else
          Process.put(:completion_message_delivered, true)
          {:deliver_text, "Late operator message", fn metadata -> send(parent, {:delivered, metadata}) end, fn _ -> :ok end}
        end

      _ ->
        :noop
    end

    assert {:ok, _} =
             CodingAgent.run_turn(session, "Start", issue(),
               on_safe_checkpoint: checkpoint,
               on_message: fn event -> send(parent, {:event, event}) end
             )

    assert_receive {:request, _first}, 1000
    assert_receive {:request, second}, 1000
    assert List.last(second.json["messages"])["content"] == "Late operator message"
    assert_receive {:event, %{event: :assistant, payload: %{text: "Operator message answered."}}}, 1000
    assert_receive {:delivered, %{checkpoint: :notification}}, 1000

    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "a queued-message notification cannot hide a pending pause", %{workspace: workspace} do
    parent = self()

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: fn request ->
                 send(parent, {:unexpected_request, request})
                 {:error, :unexpected_request}
               end
             )

    send(self(), {:agent_queue_updated, "1440", 1, false})
    send(self(), {:pause_agent, 42, 3})

    assert {:paused, %{reason: :operator_pause, request_id: 42, generation: 3}} =
             CodingAgent.run_turn(session, "Start", issue(), [])

    refute_receive {:unexpected_request, _request}, 100
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "a pause requested inside a tool batch waits until every advertised call has a result", %{
    workspace: workspace
  } do
    parent = self()

    first =
      response(%{
        "id" => "req-tool-batch",
        "choices" => [
          %{
            "finish_reason" => "tool_calls",
            "message" => %{
              "role" => "assistant",
              "tool_calls" =>
                Enum.map(1..2, fn index ->
                  %{
                    "id" => "call-#{index}",
                    "type" => "function",
                    "function" => %{"name" => "read_file", "arguments" => ~s({"path":"sample.txt"})}
                  }
                end)
            }
          }
        ]
      })

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: fn _request -> first end
             )

    checkpoint = fn
      %{kind: :tool_result} ->
        unless Process.get(:pause_sent) do
          Process.put(:pause_sent, true)
          send(self(), {:pause_agent, 42, 3})
        end

        :noop

      _ ->
        :noop
    end

    assert {:paused, %{reason: :operator_pause, request_id: 42, generation: 3}} =
             CodingAgent.run_turn(session, "Read twice", issue(),
               on_safe_checkpoint: checkpoint,
               on_message: fn event -> send(parent, {:event, event}) end
             )

    assert_receive {:event, %{event: :tool_result, payload: %{id: "call-1", success: true}}}, 1000
    assert_receive {:event, %{event: :tool_result, payload: %{id: "call-2", success: true}}}, 1000
    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end

  test "checkpoint messages follow every result in a multi-tool batch", %{
    workspace: workspace
  } do
    parent = self()

    first =
      response(%{
        "id" => "req-ordered-batch",
        "choices" => [
          %{
            "finish_reason" => "tool_calls",
            "message" => %{
              "role" => "assistant",
              "tool_calls" =>
                Enum.map(1..2, fn index ->
                  %{
                    "id" => "ordered-#{index}",
                    "type" => "function",
                    "function" => %{
                      "name" => "read_file",
                      "arguments" => ~s({"path":"sample.txt"})
                    }
                  }
                end)
            }
          }
        ]
      })

    final =
      response(%{
        "id" => "req-ordered-final",
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "Done."}
          }
        ]
      })

    {:ok, queue} = Agent.start_link(fn -> [first, final] end)

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "kimi",
               instance: instance([]),
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: queue_fun(queue, parent)
             )

    checkpoint = fn
      %{kind: :tool_result} ->
        if Process.get(:batch_message_delivered) do
          :noop
        else
          Process.put(:batch_message_delivered, true)
          {:deliver_text, "After the batch", fn _metadata -> :ok end, fn _reason -> :ok end}
        end

      _ ->
        :noop
    end

    assert {:ok, _session} =
             CodingAgent.run_turn(session, "Read twice", issue(), on_safe_checkpoint: checkpoint)

    assert_receive {:request, _first_request}, 1000
    assert_receive {:request, second_request}, 1000

    assert Enum.map(Enum.take(second_request.json["messages"], -3), fn message ->
             {message["role"], message["tool_call_id"], message["content"]}
           end) == [
             {"tool", "ordered-1", "workspace evidence\n"},
             {"tool", "ordered-2", "workspace evidence\n"},
             {"user", nil, "After the batch"}
           ]

    assert {:ok, :cleanup_proven} = CodingAgent.stop_session(session)
  end
end
