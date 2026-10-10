defmodule Aiur.Claude.TelemetryCase do
  @moduledoc false
  # Shared receiver setup and OTLP request builders for the Claude telemetry tests.
  use ExUnit.CaseTemplate

  alias Aiur.Claude.Telemetry
  alias Aiur.Claude.Telemetry.Receiver
  alias Aiur.{Issue, TrackerIdentity}

  import Plug.Conn
  import Plug.Test

  @deterministic_capability Base.url_encode64(:binary.copy(<<7>>, 32), padding: false)
  @model "claude-sonnet-4-6"

  using do
    quote do
      import ExUnit.CaptureLog
      import Aiur.Claude.TelemetryCase

      alias Aiur.Claude.{Telemetry, Telemetry.Receiver, Telemetry.UsageAdapter}
      alias Aiur.{Issue, TrackerIdentity, UsageEnvelope}
    end
  end

  setup context do
    name = Module.concat(Aiur.Claude.TelemetryCase, :"Receiver#{System.unique_integer([:positive, :monotonic])}")

    options =
      [
        name: name,
        max_inflight: 1,
        max_events_per_window: context[:max_events_per_window] || 120,
        replay_capacity: 4
      ]
      |> maybe_put_capability_fun(context[:capability_mint])

    start_supervised!({Telemetry, options})

    {:ok, tracker_identity} =
      TrackerIdentity.from_github(
        %{"node_id" => "I_kwDOTelemetry", "number" => 1123},
        {"its-everdred", "aiur"},
        {"its-everdred", "aiur"}
      )

    %{server: name, issue: %Issue{identifier: "1123", tracker_identity: tracker_identity}}
  end

  def launch(server, issue, opts \\ []) do
    assert {:ok, launch} =
             Telemetry.prepare_launch(
               issue,
               Keyword.merge(
                 [server: server, attempt_id: "attempt-1", workspace_ownership: %{generation: 7}, backend: "claude"],
                 opts
               )
             )

    launch
  end

  def issue(identifier) do
    number = String.to_integer(identifier)

    {:ok, tracker_identity} =
      TrackerIdentity.from_github(
        %{"node_id" => "I_kwDOTelemetry#{identifier}", "number" => number},
        {"its-everdred", "aiur"},
        {"its-everdred", "aiur"}
      )

    %Issue{identifier: identifier, tracker_identity: tracker_identity}
  end

  def authorization(%{env: env}) do
    {_, authorization} = Enum.find(env, fn {key, _value} -> key == "OTEL_EXPORTER_OTLP_LOGS_HEADERS" end)
    String.replace_prefix(authorization, "Authorization=", "")
  end

  def endpoint(%{env: env}) do
    env
    |> Map.new()
    |> Map.fetch!("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")
  end

  def submit(server, authorization, body) when is_map(body), do: submit(server, authorization, Jason.encode!(body))

  def submit(server, authorization, body) do
    conn =
      conn(:post, "/v1/logs", body)
      |> put_req_header("content-type", "application/json")
      |> maybe_put_authorization(authorization)

    Receiver.call(conn, registry: server)
  end

  def maybe_put_authorization(conn, nil), do: conn
  def maybe_put_authorization(conn, authorization), do: put_req_header(conn, "authorization", authorization)

  def payload(session_id, request_ids, extra_attribute \\ "")

  def payload(session_id, request_ids, extra_attribute) when is_list(request_ids) do
    %{
      "resourceLogs" => [
        %{
          "resource" => %{
            "attributes" => [
              attribute("service.name", "claude-code"),
              attribute("service.version", "2.1.210"),
              attribute("session.id", canonical_session_id(session_id))
            ]
          },
          "scopeLogs" => [%{"scope" => %{"attributes" => []}, "logRecords" => Enum.map(request_ids, &record(&1, extra_attribute))}]
        }
      ]
    }
  end

  def payload(session_id, request_id, extra_attribute), do: payload(session_id, [request_id], extra_attribute)

  def record(request_id, extra_attribute) do
    attributes =
      [
        attribute("event.name", "api_request"),
        attribute("request_id", canonical_request_id(request_id)),
        attribute("model", @model),
        attribute("event.sequence", 1),
        attribute("input_tokens", 11),
        attribute("output_tokens", 7)
      ] ++
        if(extra_attribute == "", do: [], else: [attribute("unrelated.attribute", extra_attribute)])

    %{"body" => %{"stringValue" => "claude_code.api_request"}, "attributes" => attributes}
  end

  def attribute(key, value) when is_binary(value), do: %{"key" => key, "value" => %{"stringValue" => value}}
  def attribute(key, value) when is_integer(value), do: %{"key" => key, "value" => %{"intValue" => value}}

  def oversized_payload do
    %{"resourceLogs" => String.duplicate("x", 32_769)}
  end

  def replace_attribute(value, key, replacement) when is_list(value),
    do: Enum.map(value, &replace_attribute(&1, key, replacement))

  def replace_attribute(%{"key" => key} = attribute, key, replacement),
    do: Map.put(attribute, "value", replacement)

  def replace_attribute(value, key, replacement) when is_map(value),
    do: Map.new(value, fn {map_key, map_value} -> {map_key, replace_attribute(map_value, key, replacement)} end)

  def replace_attribute(value, _key, _replacement), do: value

  def append_record_attribute(value, attribute) when is_map(value) do
    update_in(value, ["resourceLogs", Access.at(0), "scopeLogs", Access.at(0), "logRecords", Access.at(0), "attributes"], &(&1 ++ [attribute]))
  end

  def drop_attribute(value, key) when is_list(value) do
    value
    |> Enum.reject(&match?(%{"key" => ^key}, &1))
    |> Enum.map(&drop_attribute(&1, key))
  end

  def drop_attribute(value, key) when is_map(value),
    do: Map.new(value, fn {map_key, map_value} -> {map_key, drop_attribute(map_value, key)} end)

  def drop_attribute(value, _key), do: value

  def canonical_session_id(label) do
    digest = :sha256 |> :crypto.hash(label) |> Base.encode16(case: :lower)
    a = String.slice(digest, 0, 8)
    b = String.slice(digest, 8, 4)
    c = String.slice(digest, 13, 3)
    d = String.slice(digest, 17, 3)
    e = String.slice(digest, 20, 12)

    "#{a}-#{b}-4#{c}-8#{d}-#{e}"
  end

  def canonical_request_id(label) do
    suffix = :sha256 |> :crypto.hash(label) |> Base.encode16() |> binary_part(0, 24)
    "req_#{suffix}"
  end

  def maybe_put_capability_fun(opts, :deterministic), do: Keyword.put(opts, :capability_fun, fn -> @deterministic_capability end)
  def maybe_put_capability_fun(opts, _mint), do: opts
end
