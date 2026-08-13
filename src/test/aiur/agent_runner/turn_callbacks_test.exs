defmodule Aiur.AgentRunner.TurnCallbacksTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.TurnCallbacks
  alias Aiur.{Issue, TrackerIdentity, UsageEnvelope}

  describe "build/3 per-model attribution" do
    test "threads the resolved session model into live_opts" do
      callbacks = TurnCallbacks.build(session("claude", "sonnet-4-6"), issue(), opts())

      assert callbacks.live_opts[:resolved_model] == "sonnet-4-6"
    end

    test "a session without a model leaves the opts untouched" do
      callbacks = TurnCallbacks.build(%{backend: "codex"}, issue(), opts())

      refute Keyword.has_key?(callbacks.live_opts, :resolved_model)
    end

    test "attributes a claude turn completion to its resolved model" do
      parent = self()

      opts =
        opts()
        |> Keyword.put(:usage_publisher, fn envelope -> send(parent, {:published, envelope}) end)

      callbacks = TurnCallbacks.build(session("claude", "sonnet-4-6"), issue(), opts)

      payload = %{
        "method" => "turn/completed",
        "params" => %{
          "usage" => %{
            "input_tokens" => 100,
            "cache_read_input_tokens" => 30,
            "cache_creation_input_tokens" => 20,
            "output_tokens" => 10
          }
        }
      }

      callbacks.on_message.(%{event: :turn_completed, payload: payload, raw: Jason.encode!(payload)})

      assert_receive {:published, %UsageEnvelope{} = envelope}
      assert envelope.provider == :claude
      assert envelope.resolved_model == "sonnet-4-6"
    end
  end

  defp session(backend, model), do: %{backend: backend, model: model}

  defp issue do
    %Issue{
      id: "gid-tc-01",
      identifier: "TC-01",
      tracker_identity: %TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "o",
        repository: "r",
        provider_id: "node-1",
        database_id: 1,
        identifier: "1",
        reason: nil
      }
    }
  end

  defp opts do
    [
      orchestrator: self(),
      recipient: nil,
      workspace: nil,
      worker_host: nil,
      live_conversation: :disabled,
      run_id: "run-1",
      attempt_id: "a-1",
      session_id: "s-1",
      worker_generation: 1,
      source_sequence: 1,
      usage_publisher: fn _envelope -> :ok end
    ]
  end
end
