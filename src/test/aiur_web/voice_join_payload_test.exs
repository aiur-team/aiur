defmodule AiurWeb.VoiceJoinPayloadTest do
  use ExUnit.Case, async: true

  alias AiurWeb.VoiceJoinPayload

  @worker %{
    "v" => 1,
    "mode" => "dictate",
    "surface" => "agent_composer",
    "target" => %{"kind" => "worker", "ticket" => "owner/repo#123"},
    "client_session_id" => "8b1f2c3d-4e5f-4a6b-9c7d-0e1f2a3b4c5d"
  }

  test "an empty payload is today's browser: a legacy join with no target" do
    assert VoiceJoinPayload.parse(%{}) == :legacy
  end

  test "a v1 worker payload parses to its target and surface" do
    assert {:ok, %{surface: "agent_composer", target: %{kind: :worker, ticket: "owner/repo#123", instance_id: nil}}} =
             VoiceJoinPayload.parse(@worker)

    with_client = Map.put(@worker, "client", %{"kind" => "phone", "version" => "1.2.0"})
    assert {:ok, _parsed} = VoiceJoinPayload.parse(with_client)
  end

  test "a v1 command payload carries its expected version" do
    payload =
      @worker
      |> Map.put("surface", "command_response")
      |> Map.put("target", %{"kind" => "command", "decision_id" => "3f9a1c0e", "expected_version" => 7, "instance_id" => "m/k"})

    assert {:ok, %{target: %{kind: :command, decision_id: "3f9a1c0e", expected_version: 7, instance_id: "m/k"}}} =
             VoiceJoinPayload.parse(payload)
  end

  # Strictness keeps a client bug from smuggling a field the daemon never checked.
  test "anything that is not exactly the v1 shape is invalid" do
    invalid = [
      %{"v" => 2},
      Map.put(@worker, "v", 2),
      %{"surface" => "agent_composer"},
      Map.put(@worker, "mode", "converse"),
      Map.put(@worker, "surface", "home_screen"),
      Map.put(@worker, "extra", true),
      Map.delete(@worker, "client_session_id"),
      Map.put(@worker, "client_session_id", "has spaces"),
      Map.put(@worker, "client_session_id", String.duplicate("a", 65)),
      Map.put(@worker, "client", %{"kind" => "toaster"}),
      Map.put(@worker, "client", %{"kind" => "phone", "build" => "x"}),
      Map.put(@worker, "client", %{"kind" => "phone", "version" => String.duplicate("1", 257)}),
      Map.put(@worker, "target", nil),
      Map.put(@worker, "target", %{"kind" => "robot"}),
      Map.put(@worker, "target", %{"kind" => "worker"}),
      Map.put(@worker, "target", %{"kind" => "worker", "ticket" => ""}),
      Map.put(@worker, "target", %{"kind" => "worker", "ticket" => String.duplicate("x", 257)}),
      Map.put(@worker, "target", %{"kind" => "worker", "ticket" => 123}),
      Map.put(@worker, "target", %{"kind" => "worker", "ticket" => "ENG-1", "decision_id" => "d"}),
      Map.put(@worker, "target", %{"kind" => "command", "decision_id" => "d", "expected_version" => 0}),
      Map.put(@worker, "target", %{"kind" => "command", "decision_id" => "d", "expected_version" => "7"})
    ]

    for payload <- invalid do
      assert VoiceJoinPayload.parse(payload) == {:error, :invalid_payload}, "accepted #{inspect(payload)}"
    end
  end
end
