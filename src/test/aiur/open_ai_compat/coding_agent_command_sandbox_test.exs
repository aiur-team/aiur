defmodule Aiur.OpenAICompat.CodingAgentCommandSandboxTest do
  # Wiring: a `command_sandbox` in the backend config must reach the bwrap
  # argv of an exec_command tool call made through CodingAgent.
  use ExUnit.Case, async: true
  use Aiur.TestSupport.OpenAICompatAgent

  alias Aiur.OpenAICompat.CodingAgent

  test "backend_config command_sandbox reaches the exec_command bwrap args", %{workspace: workspace} do
    parent = self()
    ro = Path.join(workspace, "tools-ro")
    File.mkdir_p!(ro)

    {:ok, queue} =
      Agent.start_link(fn ->
        [
          response(%{
            "id" => "req-1",
            "model" => "deepseek-v4-flash",
            "choices" => [
              %{
                "finish_reason" => "tool_calls",
                "message" => %{
                  "role" => "assistant",
                  "content" => nil,
                  "tool_calls" => [
                    %{
                      "id" => "call-1",
                      "type" => "function",
                      "function" => %{"name" => "exec_command", "arguments" => ~s({"command":"true"})}
                    }
                  ]
                }
              }
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
          }),
          response(%{
            "id" => "req-2",
            "model" => "deepseek-v4-flash",
            "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Done."}}],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
          })
        ]
      end)

    assert {:ok, session} =
             CodingAgent.start_session(workspace,
               backend: "deepseek",
               instance: instance([]),
               backend_config: %{"command_sandbox" => %{"read_only_binds" => [ro]}},
               api_key_fetcher: fn _ -> "secret" end,
               request_fun: queue_fun(queue, parent)
             )

    runner = fn _exe, args, _opts -> send(parent, {:bwrap_args, args}) && {"ok", 0} end

    assert {:ok, _} =
             CodingAgent.run_turn(session, "run it", issue(),
               sandbox_executable: "/usr/bin/bwrap",
               system_cmd: runner
             )

    assert_receive {:bwrap_args, args}, 1000
    assert ["--ro-bind", ro, ro] in Enum.chunk_every(args, 3, 1, :discard)
  end
end
