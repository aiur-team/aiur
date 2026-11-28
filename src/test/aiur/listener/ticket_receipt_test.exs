defmodule Aiur.Listener.TicketReceiptTest do
  # A host app polls the receipt of each message it sent so its chat can show
  # queued, delivered and read. The request id is a global queue id, so a ticket
  # must never read another ticket's message through it.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [json_response: 2]
  import Plug.Test, only: [conn: 2]

  alias Aiur.Listener

  defmodule Target do
    @delivered ~U[2026-11-25 10:00:00Z]

    def read_snapshot(1, _timeout) do
      {:ok,
       %Aiur.AgentQueueItem{
         id: 1,
         target_issue_identifier: "645",
         message_id: "chat-1",
         status: :consumed,
         delivery: %{listener_mode_at_claim: :steer},
         delivered_at: @delivered,
         provider_delivered_at: @delivered,
         read_at: @delivered,
         consumed_at: @delivered
       }}
    end

    def read_snapshot(2, _timeout), do: {:ok, %Aiur.AgentQueueItem{id: 2, target_issue_identifier: "645", status: :failed, failure_reason: {:provider, :closed}, delivery: %{}}}
    def read_snapshot(_id, _timeout), do: {:ok, nil}
  end

  setup do
    previous = Application.fetch_env!(:aiur, :listener_delivery_target)
    Application.put_env(:aiur, :listener_delivery_target, Target)
    on_exit(fn -> Application.put_env(:aiur, :listener_delivery_target, previous) end)
  end

  test "a ticket reads its own message's receipt with the mode it was delivered under" do
    assert {:ok, receipt} = Listener.ticket_receipt("645", 1)
    assert %{receipt: :read, queue_status: :consumed, listener_mode: :steer, message_id: "chat-1", issue_identifier: "645"} = receipt
    assert receipt.read_at == ~U[2026-11-25 10:00:00Z]
  end

  test "another ticket's request id and an unknown id are not found" do
    assert {:error, :not_found} = Listener.ticket_receipt("632", 1)
    assert {:error, :not_found} = Listener.ticket_receipt("645", 99)
  end

  test "the receipt endpoint answers JSON, including a failure that is not a plain atom" do
    body = receipt_request("645", "2") |> json_response(200)
    assert %{"receipt" => "failed", "queue_status" => "failed", "failure_reason" => "{:provider, :closed}"} = body

    assert %{"error" => %{"code" => "message_not_found"}} = receipt_request("632", "1") |> json_response(404)
    assert %{"error" => %{"code" => "invalid_request_id"}} = receipt_request("645", "abc") |> json_response(422)
  end

  defp receipt_request(issue, request_id) do
    :get
    |> conn("/api/v1/#{issue}/messages/#{request_id}")
    |> Map.put(:path_params, %{"issue_identifier" => issue, "request_id" => request_id})
    |> Map.put(:params, %{"issue_identifier" => issue, "request_id" => request_id})
    |> AiurWeb.ObservabilityApiController.call(:message_receipt)
  end
end
