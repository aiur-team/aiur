defmodule AiurWeb.Components.VoiceDeliveryTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias AiurWeb.Components.{VoiceDelivery, VoiceInput}

  test "canonical harness receipt is echoed beside voice status and confirms acceptance" do
    delivery = VoiceDelivery.receipt([%{receipt: :harness_queued, request_id: 7, target_key: "42"}], "42", %{})
    html = render_component(&VoiceInput.voice_input/1, id: "voice", delivery: delivery)
    assert html =~ "Delivered to the agent"
    assert html |> Floki.parse_fragment!() |> Floki.find("[data-voice-root]") |> Floki.attribute("data-voice-state") == ["sent"]
    assert delivery.message_id == 7
    assert VoiceDelivery.receipt([%{receipt: :harness_queued, target_key: "other"}], "42", %{}) == nil
  end

  test "unrecognized receipt remains unknown rather than delivered" do
    html = render_component(&VoiceInput.voice_input/1, id: "voice", delivery: %{state: :weird, message_id: 7})
    assert html =~ "Delivery outcome unknown. Check the log before you send again."
    refute html =~ "Delivered to the agent"
    refute html =~ ~s(data-voice-state="sent")
  end

  test "failed and unknown receipts echo the send error and do not confirm acceptance" do
    for state <- [:failed, :outcome_unknown] do
      delivery = VoiceDelivery.receipt([%{receipt: state, target_key: "42"}], "42", %{"42" => "Keep the draft and retry."})
      html = render_component(&VoiceInput.voice_input/1, id: "voice", delivery: delivery)
      assert html =~ "Keep the draft and retry."
      refute html =~ ~s(data-voice-state="sent")
    end
  end

  test "Command echo uses the canonical queued notice and retains rejection copy" do
    decision = %{decision_status: :decided, pending_for_session?: true, answer: %{}, ticket: %{identifier: "42"}}
    delivery = VoiceDelivery.command(decision, %{})
    assert delivery == %{state: :accepted, copy: "Answer recorded. #42 is not running; it will receive it when it restarts."}
    html = render_component(&VoiceInput.delivery_status/1, delivery: delivery)
    assert html =~ ~s(data-voice-state="sent")
    assert html =~ "it will receive it when it restarts."
    rejected = VoiceDelivery.command(%{decision_status: :open}, %{error: "This Command changed."})
    assert rejected == %{state: :failed, copy: "This Command changed."}
  end
end
