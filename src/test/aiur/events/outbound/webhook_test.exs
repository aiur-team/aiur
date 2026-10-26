defmodule Aiur.Events.Outbound.WebhookTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.Outbound.Webhook

  @secret "whsec_MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="
  @timestamp 1_792_886_400
  @body ~s({"anchor":null,"attrs":{"lifecycle":"running","lifecycle_source":"tracker"},"class":"live","id":101,"instance":"host/default","observed_at":"2026-10-25T00:00:00Z","occurred_at":"2026-10-25T00:00:00Z","payload_version":1,"refs":{"job_id":"run-5695-1","ticket":"5695"},"seq":1,"source":"legacy","topic":"ticket.5695.lifecycle.changed","v":1})

  test "matches the cross-language Standard Webhooks signature vector" do
    assert Webhook.sign(@secret, "host/default/101", @timestamp, @body) ==
             "v1,AMeDHsQnunjDAaXb9UkZ2N26t1CragO3VW1mczNNUpk="
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
    assert Keyword.fetch!(opts, :url) == "https://93.184.216.34/aiur"
    assert Keyword.fetch!(opts, :redirect) == false
    assert Keyword.fetch!(opts, :retry) == false
    assert Keyword.fetch!(opts, :receive_timeout) == 2_500
    assert Keyword.fetch!(opts, :connect_options) == [timeout: 2_500, hostname: "consumer.example.test"]

    headers = Map.new(Keyword.fetch!(opts, :headers))
    assert headers["content-type"] == "application/json"
    assert headers["host"] == "consumer.example.test"
    assert headers["webhook-id"] == "host/default/101"
    assert headers["webhook-timestamp"] == Integer.to_string(@timestamp)
    assert headers["webhook-signature"] == Webhook.sign(@secret, "host/default/101", @timestamp, body)
  end

  test "holds the durable cursor on redirect, retryable HTTP, and transport failures" do
    for result <- [
          {:ok, %Req.Response{status: 302}},
          {:ok, %Req.Response{status: 408}},
          {:ok, %Req.Response{status: 429}},
          {:ok, %Req.Response{status: 503}},
          {:error, %RuntimeError{message: "closed"}}
        ] do
      state = webhook_state(request_fun: fn _opts -> result end)
      assert {:error, _reason} = Webhook.handle_record(%{"seq" => 1, "event" => event()}, state)
    end
  end

  test "preserves a non-default port in the Host header while pinning DNS" do
    test = self()

    state =
      webhook_state(
        url: "https://consumer.example.test:8443/aiur",
        resolve_fun: fn "https://consumer.example.test:8443/aiur", false ->
          {:ok, "https://93.184.216.34:8443/aiur", "consumer.example.test"}
        end,
        request_fun: fn opts ->
          send(test, {:request, opts})
          {:ok, %Req.Response{status: 204}}
        end
      )

    assert {:ok, ^state} = Webhook.handle_record(%{"seq" => 1, "event" => event()}, state)
    assert_receive {:request, opts}, 1_000
    assert {"host", "consumer.example.test:8443"} in Keyword.fetch!(opts, :headers)
    assert Keyword.fetch!(opts, :connect_options)[:hostname] == "consumer.example.test"
  end

  test "discards a permanent 4xx response and raises attention without exposing the URL" do
    test = self()

    alert_fun = fn topic, opts ->
      send(test, {:alert, topic, opts})
      :ok
    end

    state = webhook_state(request_fun: fn _opts -> {:ok, %Req.Response{status: 422}} end, alert_fun: alert_fun)

    assert {:discard, {:http_status, 422}, ^state} =
             Webhook.handle_record(%{"seq" => 1, "event" => event()}, state)

    assert_receive {:alert, "system.outbound_events.delivery.permanent_failure", opts}, 1_000
    assert opts[:needs_attention]
    assert opts[:reason] =~ "host/default/101"
    refute opts[:reason] =~ "consumer.example.test"
  end

  test "refuses a destination that resolves to a private address before posting" do
    state =
      webhook_state(
        resolve_fun: fn _url, false -> {:error, :private_destination_forbidden} end,
        request_fun: fn _opts -> flunk("a rejected destination must not be contacted") end
      )

    assert {:error, :destination_unavailable} =
             Webhook.handle_record(%{"seq" => 1, "event" => event()}, state)
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
      resolve_fun: fn "https://consumer.example.test/aiur", false ->
        {:ok, "https://93.184.216.34/aiur", "consumer.example.test"}
      end,
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
