defmodule Aiur.Events.Outbound.WebhookTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.Outbound.Webhook

  @secret "whsec_MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="
  @timestamp 1_792_886_400
  @body ~s({"contract":"aiur.ticket_lifecycle_event","contract_version":1,"event_id":"evt_101","event_type":"ticket.lifecycle.changed","emitted_at":"2026-10-25T00:00:00Z","ticket_id":"5695","job_id":"run-5695-1","data":{"lifecycle":"running","source":"tracker","observed_at":"2026-10-25T00:00:00Z"}})

  test "matches the cross-language Standard Webhooks signature vector" do
    assert Webhook.sign(@secret, "evt_101", @timestamp, @body) ==
             "v1,x6NtCsb4O8VSnXhPaKG1+9ahN6zNY6uuuZidWBVLbDA="
  end

  test "posts the exact signed body and acknowledges only a 2xx response" do
    test = self()

    request_fun = fn opts ->
      send(test, {:request, opts})
      {:ok, %Req.Response{status: 204}}
    end

    state = webhook_state(request_fun: request_fun)
    record = %{"seq" => 1, "event" => event()}
    assert {:ok, ^state} = Webhook.handle_record(record, state)
    assert_receive {:request, opts}, 1_000

    body = Keyword.fetch!(opts, :body)
    assert Jason.decode!(body) == event()
    assert Keyword.fetch!(opts, :url) == "https://consumer.example.test/aiur"
    assert Keyword.fetch!(opts, :redirect) == false
    assert Keyword.fetch!(opts, :retry) == false
    assert Keyword.fetch!(opts, :receive_timeout) == 2_500

    headers = Map.new(Keyword.fetch!(opts, :headers))
    assert headers["content-type"] == "application/json"
    assert headers["webhook-id"] == "evt_101"
    assert headers["webhook-timestamp"] == Integer.to_string(@timestamp)
    assert headers["webhook-signature"] == Webhook.sign(@secret, "evt_101", @timestamp, body)
  end

  test "holds the durable cursor on HTTP, redirect, and transport failures" do
    for result <- [
          {:ok, %Req.Response{status: 302}},
          {:ok, %Req.Response{status: 503}},
          {:error, %RuntimeError{message: "closed"}}
        ] do
      state = webhook_state(request_fun: fn _opts -> result end)
      assert {:error, _reason} = Webhook.handle_record(%{"seq" => 1, "event" => event()}, state)
    end
  end

  test "advances past records outside the configured ticket or job subscription without posting" do
    request_fun = fn _opts -> flunk("filtered event must not be posted") end
    state = webhook_state(request_fun: request_fun, subject_id: "other")

    assert {:ok, ^state} = Webhook.handle_record(%{"seq" => 1, "event" => event()}, state)
  end

  defp webhook_state(overrides) do
    defaults = [
      url: "https://consumer.example.test/aiur",
      secret: @secret,
      subject_id: nil,
      request_timeout_ms: 2_500,
      clock: fn -> DateTime.from_unix!(@timestamp) end
    ]

    defaults
    |> Keyword.merge(overrides)
    |> Webhook.new!()
  end

  defp event do
    Jason.decode!(@body)
  end
end
