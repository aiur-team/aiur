defmodule Aiur.Events.Outbound.WebhookTest do
  @moduledoc "Covers outbound webhook signing, delivery, and cursor behavior across event families."

  use ExUnit.Case, async: true

  alias Aiur.Events.Envelope
  alias Aiur.Events.Outbound.Webhook
  alias Aiur.TicketObservation

  @decision_fixture Path.expand("../../../../../packages/aiur-contracts/fixtures/ticket-decision-event.v1.json", __DIR__)

  @signature_vector Path.expand(
                      "../../../../../packages/aiur-contracts/fixtures/webhook-signature-vector.v1.json",
                      __DIR__
                    )

  test "matches the cross-language Standard Webhooks signature vector" do
    vector = signature_vector()

    assert Webhook.sign(vector["secret"], vector["msg_id"], vector["timestamp"], vector["body"]) ==
             vector["signature"]
  end

  test "posts the exact signed body and acknowledges only a 2xx response" do
    test = self()
    vector = signature_vector()

    request_fun = fn opts ->
      send(test, {:request, opts})
      {:ok, %Req.Response{status: 204}}
    end

    state = webhook_state(request_fun: request_fun)
    record = record()
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
    assert headers["webhook-id"] == vector["msg_id"]
    assert headers["webhook-timestamp"] == Integer.to_string(vector["timestamp"])

    assert headers["webhook-signature"] ==
             Webhook.sign(vector["secret"], vector["msg_id"], vector["timestamp"], body)
  end

  test "signs the decision envelope fixture and omits secrets and unapproved fields" do
    test = self()
    vector = signature_vector()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    decision = %{
      id: 106,
      topic: "ticket.5695.agent.decision.answered",
      decision_id: "dec_123",
      decision_version: 2,
      question: "Should the change be deployed?",
      options: [%{id: "deploy", label: "Deploy", description: nil, benefits: nil, drawbacks: nil, risk: nil, token: "never-export-this-token"}],
      answer: %{selected_option_id: "deploy", custom_response: nil, rationale: "The checks passed.", token: "never-export-this-token"},
      token: "never-export-this-token",
      secret: "sk-abcdefghijklmnopqrstuvwxyz",
      ticket_observation: %TicketObservation{
        status: :joinable,
        source: %{kind: :legacy},
        event_id: 106,
        provenance: %{},
        occurred_at: now,
        observed_at: DateTime.add(now, 1, :second),
        attributes: %{}
      }
    }

    assert {:ok, envelope} = Envelope.to_external(decision, instance: "host/default")
    record = envelope |> Map.put("seq", 6) |> Map.put("type", "event")

    state =
      webhook_state(
        request_fun: fn opts ->
          send(test, {:request, opts})
          {:ok, %Req.Response{status: 204}}
        end
      )

    assert {:ok, ^state} = Webhook.handle_record(record, state)
    assert_receive {:request, opts}, 1_000
    body = Keyword.fetch!(opts, :body)

    expected =
      @decision_fixture
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("occurred_at", DateTime.to_iso8601(now))
      |> Map.put("observed_at", DateTime.add(now, 1, :second) |> DateTime.to_iso8601())

    assert Jason.decode!(body) == expected
    refute body =~ "never-export-this-token"
    refute body =~ "sk-abcdefghijklmnopqrstuvwxyz"

    headers = Map.new(Keyword.fetch!(opts, :headers))
    assert headers["webhook-signature"] == Webhook.sign(vector["secret"], headers["webhook-id"], vector["timestamp"], body)
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
      assert {:error, _reason} = Webhook.handle_record(record(), state)
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

    assert {:ok, ^state} = Webhook.handle_record(record(), state)
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
             Webhook.handle_record(record(), state)

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
             Webhook.handle_record(record(), state)
  end

  test "advances past records outside the configured ticket or job subscription without posting" do
    request_fun = fn _opts -> flunk("filtered event must not be posted") end
    state = webhook_state(request_fun: request_fun, subject_id: "other")

    assert {:ok, ^state} = Webhook.handle_record(record(), state)
  end

  test "advances past journal gaps and other exported families without posting" do
    state = webhook_state(request_fun: fn _opts -> flunk("non-webhook records must not be posted") end)

    assert {:ok, ^state} = Webhook.handle_record(%{"type" => "gap", "seq" => 1}, state)

    assert {:ok, ^state} =
             Webhook.handle_record(
               %{"type" => "event", "seq" => 2, "instance" => "host/default", "id" => 22, "topic" => "ticket.5695.pr.merged"},
               state
             )
  end

  defp webhook_state(overrides) do
    vector = signature_vector()

    defaults = [
      url: "https://consumer.example.test/aiur",
      secret: vector["secret"],
      subject_id: nil,
      request_timeout_ms: 2_500,
      resolve_fun: fn "https://consumer.example.test/aiur", false ->
        {:ok, "https://93.184.216.34/aiur", "consumer.example.test"}
      end,
      clock: fn -> DateTime.from_unix!(vector["timestamp"]) end
    ]

    defaults
    |> Keyword.merge(overrides)
    |> Webhook.new!()
  end

  defp event do
    signature_vector()["body"] |> Jason.decode!()
  end

  defp record, do: event() |> Map.put("type", "event")

  defp signature_vector do
    @signature_vector |> File.read!() |> Jason.decode!()
  end
end
