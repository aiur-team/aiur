defmodule Aiur.OpenAICompat.DecisionMediaTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.DecisionApi.PublicProjection
  alias Aiur.{DecisionStore, DecisionValidation, Issue}
  alias Aiur.OpenAICompat.Tools

  # Shell-only workers cannot reach the daemon's control RPC, so the route for an
  # OpenAI-compatible worker is the advertised emit_event tool, which validates
  # media through the same Commands path as `aiur command request --media`.
  setup do
    base = DecisionValidation.safe_roots() |> Enum.find(&(Path.type(&1) == :absolute))
    root = Path.join(base, "aiur-openai-media-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    image = Path.join(root, "prototype.png")
    File.write!(image, "png")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{image: image}
  end

  test "an OpenAI-compatible worker's emit_event raises a media Command stored as an attachment", %{image: image} do
    identifier = "OAI-media-#{System.unique_integer([:positive])}"
    executor = ToolExecutor.build(%Issue{identifier: identifier}, nil, nil, %{backend: "openrouter", thread_id: "thread-oai"})

    assert "emit_event" in Enum.map(Tools.specs(:chat_completions), & &1["function"]["name"])

    arguments =
      Jason.encode!(%{
        "name" => "decision.requested",
        "message" => "Which prototype?",
        "payload" => %{
          "blocking" => false,
          "media" => [%{"kind" => "image", "mime_type" => "image/png", "locator" => image, "alt_text" => "Prototype"}],
          "options" => [%{"id" => "a", "label" => "Keep"}, %{"id" => "b", "label" => "Redo"}]
        }
      })

    assert {:ok, decoded} = Tools.decode_and_validate("emit_event", arguments)
    response = Tools.execute("emit_event", decoded, %{workspace: nil, tool_executor: executor}, [])
    assert response["success"] == true, inspect(response)

    {:ok, decision} = DecisionStore.get(Jason.decode!(response["output"])["result"]["decision_id"])
    assert [%{kind: :image, alt_text: "Prototype", attachment_id: "med_" <> _ = id}] = decision.media

    projection = decision |> PublicProjection.encode() |> Jason.encode!()
    assert projection =~ id
    refute projection =~ Path.dirname(image)
  end
end
