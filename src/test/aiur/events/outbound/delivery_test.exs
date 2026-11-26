defmodule Aiur.Events.Outbound.DeliveryTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.Outbound.Delivery
  alias Aiur.JsonStore

  defmodule Source do
    @behaviour Aiur.Events.DurableConsumer.Source

    def start_link, do: Agent.start_link(fn -> %{records: [], consumers: []} end)

    def append(source, record) do
      Agent.update(source, fn state ->
        Enum.each(state.consumers, &send(&1, {:durable_record, record}))
        %{state | records: state.records ++ [record]}
      end)
    end

    @impl true
    def subscribe(source, consumer), do: Agent.update(source, &%{&1 | consumers: [consumer | &1.consumers]})

    @impl true
    def replay(source, cursor, limit) do
      records = Agent.get(source, & &1.records)
      {:ok, records |> Enum.filter(&(&1["seq"] > cursor)) |> Enum.take(limit)}
    end

    @impl true
    def position(record), do: Map.fetch!(record, "seq")
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "outbound-delivery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    {:ok, source} = Source.start_link()
    {:ok, dir: dir, cursor_path: Path.join(dir, "cursor.json"), source: source}
  end

  test "retries the same signed event and advances the cursor only after acknowledgement", ctx do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    test = self()

    request_fun = fn opts ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
      send(test, {:attempt, attempt, Keyword.fetch!(opts, :body)})
      {:ok, %Req.Response{status: if(attempt == 1, do: 503, else: 204)}}
    end

    delivery =
      start_supervised!(
        {Delivery,
         name: nil,
         source: {Source, ctx.source},
         cursor_path: ctx.cursor_path,
         export: export_config(1),
         secret: secret(),
         request_fun: request_fun,
         resolve_fun: &resolve_public/2,
         retry_ms: 1,
         retry_max_ms: 4,
         jitter_fun: fn _window -> 0 end}
      )

    :sys.get_state(delivery)
    Source.append(ctx.source, record(101, 1))
    assert_receive {:attempt, 1, body}, 1_000
    assert_receive {:attempt, 2, ^body}, 1_000
    assert :sys.get_state(delivery).cursor == 1
    assert {:ok, %{"cursor" => 1}} = JsonStore.read(ctx.cursor_path)
  end

  test "a permanent 4xx is skipped with attention so the next event can be delivered", ctx do
    test = self()

    request_fun = fn opts ->
      event_id = opts |> Keyword.fetch!(:body) |> Jason.decode!() |> Map.fetch!("id")
      send(test, {:delivered, event_id})
      {:ok, %Req.Response{status: if(event_id == 101, do: 422, else: 204)}}
    end

    alert_fun = fn topic, opts ->
      send(test, {:alert, topic, opts})
      :ok
    end

    delivery =
      start_supervised!(
        {Delivery,
         name: nil,
         source: {Source, ctx.source},
         cursor_path: ctx.cursor_path,
         export: export_config(10),
         secret: secret(),
         request_fun: request_fun,
         resolve_fun: &resolve_public/2,
         alert_fun: alert_fun}
      )

    :sys.get_state(delivery)
    Source.append(ctx.source, record(101, 1))
    Source.append(ctx.source, record(102, 2))
    assert_receive {:delivered, 101}, 1_000
    assert_receive {:alert, "system.outbound_events.delivery.permanent_failure", _opts}, 1_000
    assert_receive {:delivered, 102}, 1_000
    assert :sys.get_state(delivery).cursor == 2
    assert {:ok, %{"cursor" => 2}} = JsonStore.read(ctx.cursor_path)
  end

  defp record(id, seq), do: event(id, seq) |> Map.put("type", "event")

  defp event(id, seq) do
    %{
      "v" => 1,
      "instance" => "host/default",
      "seq" => seq,
      "id" => id,
      "topic" => "ticket.5695.lifecycle.changed",
      "class" => "live",
      "occurred_at" => "2026-10-25T00:00:00Z",
      "observed_at" => "2026-10-25T00:00:00Z",
      "source" => "legacy",
      "refs" => %{"ticket" => "5695", "job_id" => "run-5695-1"},
      "attrs" => %{"lifecycle" => "running", "lifecycle_source" => "tracker"},
      "payload_version" => 1,
      "anchor" => nil
    }
  end

  defp export_config(retry_ms) do
    %{webhook_url: "https://consumer.example.test/aiur", subject_id: nil, request_timeout_ms: 1_000, retry_ms: retry_ms}
  end

  defp secret, do: "whsec_MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="

  defp resolve_public("https://consumer.example.test/aiur", false),
    do: {:ok, "https://93.184.216.34/aiur", "consumer.example.test"}
end
