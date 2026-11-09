defmodule AiurWeb.Conversation.DeliveryOverlayTest do
  use ExUnit.Case, async: true
  alias Aiur.Conversation.Entry
  alias AiurWeb.Conversation.DeliveryOverlay

  test "journal operator delivery ID removes only its overlay item" do
    overlay = accepted() |> DeliveryOverlay.put_send("other", "other text", {:ok, 43}, 0)
    agent_entry = %Entry{kind: "message", refs: %{delivery_id: "42"}}
    assert DeliveryOverlay.reconcile(overlay, [agent_entry]) == overlay
    entry = %{agent_entry | kind: "operator_message"}
    reconciled = DeliveryOverlay.reconcile(overlay, [entry])
    refute Map.has_key?(reconciled, 42)
    assert reconciled[43].text == "other text"
  end

  test "outcome unknown stays terminal until retry, which replaces the client observation" do
    overlay = DeliveryOverlay.put_send(%{}, "client", "hello", {:error, {:outcome_unknown, %{item_id: nil}}}, 0)
    assert overlay["client"].state == :unknown
    refute DeliveryOverlay.pending?(overlay)
    assert DeliveryOverlay.poll(overlay, fn _ -> flunk("unknown must not poll") end, 1) == overlay
    retried = DeliveryOverlay.put_send(overlay, "client", "hello", {:ok, 42}, 2)
    assert Map.keys(retried) == [42]
    assert retried[42].state == :accepted
    assert retried[42].client_id == "client"
    assert retried[42].started_at == 0
    assert DeliveryOverlay.pending?(retried)
  end

  test "harness and read receipts remain queued until journal reconciliation" do
    for receipt <- [:harness_queued, :read, :in_context] do
      overlay = DeliveryOverlay.poll(accepted(), fn 42 -> {:ok, %{receipt: receipt}} end, 2_000)
      assert overlay[42].state == :queued
      assert overlay[42].updated_at == 2_000
      assert DeliveryOverlay.pending?(overlay)
    end
  end

  test "ten minutes without a journal entry becomes unknown and stops polling" do
    before = DeliveryOverlay.poll(accepted(), fn 42 -> {:ok, %{receipt: :accepted}} end, 599_999)
    assert before[42].state == :accepted
    expired = DeliveryOverlay.poll(before, fn 42 -> {:ok, %{receipt: :harness_queued}} end, 600_000)
    assert expired[42].state == :unknown
    assert expired[42].reason == :journal_timeout
    refute DeliveryOverlay.pending?(expired)
  end

  test "held async remains saved past ten minutes" do
    held = DeliveryOverlay.poll(accepted(), fn 42 -> {:ok, %{receipt: :held_async}} end, 600_000)
    assert held[42].state == :held_async
    assert DeliveryOverlay.pending?(held)
    assert DeliveryOverlay.poll(held, fn 42 -> {:ok, %{receipt: :held_async}} end, 1_200_000)[42].state == :held_async
  end

  test "receipt errors and unknown receipts preserve uncertainty after queue loss" do
    for receipt <- [{:error, :unavailable}, {:ok, %{receipt: :unknown}}] do
      overlay = DeliveryOverlay.poll(accepted(), fn 42 -> receipt end, 2_000)
      assert overlay[42].state == :unknown
      refute DeliveryOverlay.pending?(overlay)
    end
  end

  test "send and receipt failures retain the text and the actual failure reason" do
    rejected = DeliveryOverlay.put_send(%{}, "client", "hello", {:error, :no_running_agent}, 0)
    assert rejected["client"].state == :failed
    assert rejected["client"].reason == :no_running_agent
    assert rejected["client"].text == "hello"
    failed = DeliveryOverlay.poll(accepted(), fn 42 -> {:ok, %{receipt: :failed, failure_reason: :provider_rejected}} end, 2_000)
    assert failed[42].state == :failed
    assert failed[42].reason == :provider_rejected
    assert failed[42].text == "hello"
    refute DeliveryOverlay.pending?(failed)
  end

  defp accepted, do: DeliveryOverlay.put_send(%{}, "client", "hello", {:ok, 42}, 0)
end
