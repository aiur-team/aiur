defmodule VoiceConverse.ProviderCleanupTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.ProviderCleanup
  alias VoiceConverse.Testing.StaticCredentials

  @conversation_id "vc_" <> String.duplicate("a", 22)
  @provider_id "provider-conversation-1"
  @now ~U[2026-10-24 00:00:00Z]

  setup do
    root = Path.join(System.tmp_dir!(), "voice_converse_cleanup_#{System.unique_integer([:positive])}")
    StaticCredentials.put(%{elevenlabs: "xi-test-secret"})

    on_exit(fn ->
      StaticCredentials.put(%{})
      remove_root!(root)
    end)

    %{root: root}
  end

  test "a successful delete marks the item done", %{root: root} do
    {:ok, cleanup} = start_cleanup(root, responses: [{:ok, 204, ""}])
    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    assert_receive {:scheduled, 0}
    send(cleanup, :run_provider_cleanup)

    assert_receive {:delete, "https://api.elevenlabs.io/v1/convai/conversations/#{@provider_id}", headers}
    assert {"xi-api-key", "xi-test-secret"} in headers
    sync(cleanup)
    assert queue_records(root) == ["enqueue", "done"]
  end

  test "404 counts as done", %{root: root} do
    {:ok, cleanup} = start_cleanup(root, responses: [{:ok, 404, ""}])
    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    assert_receive {:scheduled, 0}
    send(cleanup, :run_provider_cleanup)

    assert_receive {:delete, _, _}
    sync(cleanup)
    assert queue_records(root) == ["enqueue", "done"]
  end

  test "a server failure retries on the documented schedule", %{root: root} do
    clock = clock_at(@now)
    {:ok, cleanup} = start_cleanup(root, responses: [{:ok, 500, ""}, {:ok, 500, ""}], clock: clock(clock))
    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    assert_receive {:scheduled, 0}
    send(cleanup, :run_provider_cleanup)
    assert_receive {:scheduled, 30_000}

    advance_clock(clock, 30_000)
    send(cleanup, :run_provider_cleanup)
    assert_receive {:scheduled, 120_000}
  end

  test "pending deletions survive a restart", %{root: root} do
    {:ok, cleanup} = start_cleanup(root, responses: [{:ok, 500, ""}])
    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    assert_receive {:scheduled, 0}
    send(cleanup, :run_provider_cleanup)
    assert_receive {:scheduled, 30_000}
    assert_receive {:delete, _, _}
    GenServer.stop(cleanup, :normal)

    {:ok, restarted} = start_cleanup(root, responses: [{:ok, 204, ""}], clock: fn -> advance(@now, 30_000) end)
    assert_receive {:scheduled, 0}
    send(restarted, :run_provider_cleanup)

    sync(restarted)
    assert queue_records(root) == ["enqueue", "enqueue", "done"]
  end

  test "401 pauses the queue and emits one auth-failure event", %{root: root} do
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:voice_converse, :provider_cleanup, :auth_failure],
        &__MODULE__.telemetry_handler/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, cleanup} = start_cleanup(root, responses: [{:ok, 401, ""}])

    for n <- 1..3 do
      assert :ok = ProviderCleanup.enqueue(cleanup, "provider-conversation-#{n}", @conversation_id)
    end

    assert_receive {:scheduled, 0}

    send(cleanup, :run_provider_cleanup)

    assert_receive {:telemetry, [:voice_converse, :provider_cleanup, :auth_failure], %{count: 1}, %{}}
    refute_receive {:scheduled, _}
    refute_receive {:telemetry, [:voice_converse, :provider_cleanup, :auth_failure], _, _}
  end

  test "an auth pause survives restart until an explicit resume", %{root: root} do
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:voice_converse, :provider_cleanup, :auth_failure],
        &__MODULE__.telemetry_handler/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, cleanup} = start_cleanup(root, responses: [{:ok, 401, ""}])
    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    assert_receive {:scheduled, 0}
    send(cleanup, :run_provider_cleanup)
    assert_receive {:telemetry, [:voice_converse, :provider_cleanup, :auth_failure], %{count: 1}, %{}}
    GenServer.stop(cleanup, :normal)

    {:ok, restarted} = start_cleanup(root, responses: [{:ok, 204, ""}])
    refute_receive {:scheduled, _}
    refute_receive {:telemetry, [:voice_converse, :provider_cleanup, :auth_failure], _, _}
    assert :ok = ProviderCleanup.resume(restarted)
    assert_receive {:scheduled, 0}
    send(restarted, :run_provider_cleanup)
    assert_receive {:delete, _, _}
  end

  test "a missing credential pauses until resume finds a replacement", %{root: root} do
    {:ok, cleanup} = start_cleanup(root, responses: [{:ok, 204, ""}])
    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    assert_receive {:scheduled, 0}
    StaticCredentials.put(%{})
    send(cleanup, :run_provider_cleanup)
    refute_receive {:delete, _, _}
    refute_receive {:scheduled, _}

    StaticCredentials.put(%{elevenlabs: "replacement"})
    assert :ok = ProviderCleanup.resume(cleanup)
    assert_receive {:scheduled, 0}
    send(cleanup, :run_provider_cleanup)
    assert_receive {:delete, _, [{"xi-api-key", "replacement"}]}
  end

  test "a torn queue tail is skipped, sealed, and does not corrupt the next record", %{root: root} do
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:voice_converse, :provider_cleanup, :queue_recovery],
        &__MODULE__.telemetry_handler/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    File.write!(
      Path.join(root, "provider-cleanup.ndjson"),
      Jason.encode!(%{
        "op" => "enqueue",
        "provider_id" => @provider_id,
        "conversation_id" => @conversation_id,
        "at" => "now"
      }) <>
        "\n{\"op\":"
    )

    File.chmod!(Path.join(root, "provider-cleanup.ndjson"), 0o600)
    {:ok, cleanup} = start_cleanup(root, responses: [{:ok, 204, ""}])

    assert_receive {:telemetry, [:voice_converse, :provider_cleanup, :queue_recovery], %{count: 1}, %{}}
    assert_receive {:scheduled, 0}
    send(cleanup, :run_provider_cleanup)
    assert_receive {:delete, _, _}
    sync(cleanup)
    GenServer.stop(cleanup, :normal)

    {:ok, restarted} = start_cleanup(root, responses: [])
    refute_receive {:scheduled, _}
    sync(restarted)
    assert queue_records(root) == ["enqueue", "done"]
  end

  test "a failed queue write schedules another durable retry", %{root: root} do
    clock = clock_at(@now)
    {:ok, writes} = Agent.start_link(fn -> [:ok, :fail, :ok, :ok] end)

    writer = fn writer_root, record ->
      Agent.get_and_update(writes, fn
        [:ok | rest] -> {write_record(writer_root, record), rest}
        [:fail | rest] -> {{:error, :enospc}, rest}
      end)
    end

    {:ok, cleanup} =
      start_cleanup(root,
        responses: [{:ok, 204, ""}, {:ok, 204, ""}],
        writer: writer,
        clock: clock(clock)
      )

    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    assert_receive {:scheduled, 0}
    send(cleanup, :run_provider_cleanup)
    assert_receive {:scheduled, 30_000}

    advance_clock(clock, 30_000)
    send(cleanup, :run_provider_cleanup)
    sync(cleanup)
    assert queue_records(root) == ["enqueue", "enqueue", "done"]
  end

  test "persistent queue-write failures still advance retry backoff", %{root: root} do
    clock = clock_at(@now)
    {:ok, writes} = Agent.start_link(fn -> [:ok, :fail, :fail, :fail, :fail, :fail, :fail] end)

    writer = fn writer_root, record ->
      Agent.get_and_update(writes, fn
        [:ok | rest] -> {write_record(writer_root, record), rest}
        [:fail | rest] -> {{:error, :enospc}, rest}
      end)
    end

    {:ok, cleanup} =
      start_cleanup(root,
        responses: [{:ok, 204, ""}, {:ok, 204, ""}, {:ok, 204, ""}],
        writer: writer,
        clock: clock(clock)
      )

    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    assert_receive {:scheduled, 0}
    send(cleanup, :run_provider_cleanup)
    assert_receive {:scheduled, 30_000}

    advance_clock(clock, 30_000)
    send(cleanup, :run_provider_cleanup)
    assert_receive {:scheduled, 120_000}

    advance_clock(clock, 120_000)
    send(cleanup, :run_provider_cleanup)
    assert_receive {:scheduled, 600_000}
  end

  test "give-up is durable and emits telemetry without a provider id", %{root: root} do
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:voice_converse, :provider_cleanup, :give_up],
        &__MODULE__.telemetry_handler/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, cleanup} = start_cleanup(root, responses: [{:ok, 500, ""}], retry_delays: [])
    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    assert_receive {:scheduled, 0}
    send(cleanup, :run_provider_cleanup)

    assert_receive {:telemetry, [:voice_converse, :provider_cleanup, :give_up], %{count: 1}, %{}}
    assert queue_records(root) == ["enqueue", "gave_up"]
  end

  test "enqueue before the first scheduled run is durable", %{root: root} do
    {:ok, cleanup} = start_cleanup(root, responses: [{:ok, 204, ""}])
    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    assert_receive {:scheduled, 0}
    GenServer.stop(cleanup, :normal)

    {:ok, restarted} = start_cleanup(root, responses: [{:ok, 204, ""}])
    assert_receive {:scheduled, 0}
    send(restarted, :run_provider_cleanup)

    sync(restarted)
    assert queue_records(root) == ["enqueue", "done"]
  end

  test "re-enqueuing a pending provider id keeps its retry attempt", %{root: root} do
    {:ok, cleanup} = start_cleanup(root, responses: [{:ok, 500, ""}])
    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    assert_receive {:scheduled, 0}
    send(cleanup, :run_provider_cleanup)
    assert_receive {:scheduled, 30_000}

    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    refute_receive {:scheduled, 0}
    assert [enqueue, retry] = queue_records_data(root)
    assert retry["attempt"] == 1
    assert retry["next_attempt_at"] == advance(@now, 30_000) |> DateTime.to_iso8601()
    assert enqueue["provider_id"] == retry["provider_id"]
  end

  test "a delayed retry does not block another due deletion", %{root: root} do
    {:ok, cleanup} = start_cleanup(root, responses: [{:ok, 500, ""}, {:ok, 204, ""}])
    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    assert_receive {:scheduled, 0}
    send(cleanup, :run_provider_cleanup)
    assert_receive {:scheduled, 30_000}

    second_provider_id = "provider-conversation-2"
    assert :ok = ProviderCleanup.enqueue(cleanup, second_provider_id, @conversation_id)
    assert_receive {:scheduled, 0}
    send(cleanup, :run_provider_cleanup)

    second_url = "https://api.elevenlabs.io/v1/convai/conversations/#{second_provider_id}"
    assert_receive {:delete, ^second_url, _}
  end

  test "a restart retains the next retry deadline", %{root: root} do
    {:ok, cleanup} = start_cleanup(root, responses: [{:ok, 500, ""}])
    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    assert_receive {:scheduled, 0}
    send(cleanup, :run_provider_cleanup)
    assert_receive {:scheduled, 30_000}
    assert_receive {:delete, _, _}
    GenServer.stop(cleanup, :normal)

    {:ok, restarted} = start_cleanup(root, responses: [{:ok, 204, ""}])
    assert_receive {:scheduled, 30_000}
    send(restarted, :run_provider_cleanup)
    refute_receive {:delete, _, _}
  end

  test "the default retry budget gives up after all twelve scheduled retries", %{root: root} do
    clock = clock_at(@now)
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:voice_converse, :provider_cleanup, :give_up],
        &__MODULE__.telemetry_handler/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, cleanup} = start_cleanup(root, responses: List.duplicate({:ok, 500, ""}, 13), clock: clock(clock))
    assert :ok = ProviderCleanup.enqueue(cleanup, @provider_id, @conversation_id)
    assert_receive {:scheduled, 0}

    for delay <- [30_000, 120_000, 600_000, 3_600_000, 21_600_000 | List.duplicate(86_400_000, 7)] do
      send(cleanup, :run_provider_cleanup)
      assert_receive {:scheduled, ^delay}, 1_000
      advance_clock(clock, delay)
    end

    send(cleanup, :run_provider_cleanup)
    assert_receive {:telemetry, [:voice_converse, :provider_cleanup, :give_up], %{count: 1}, %{}}
    assert queue_records(root) |> List.last() == "gave_up"
  end

  defp start_cleanup(root, opts) do
    parent = self()
    responses = Keyword.fetch!(opts, :responses)
    {:ok, response_agent} = Agent.start_link(fn -> responses end)

    {:ok, cleanup} =
      ProviderCleanup.start_link(
        name: nil,
        transcript_root: root,
        credentials: {StaticCredentials, :elevenlabs},
        http: fn url, request_opts ->
          send(parent, {:delete, url, Keyword.fetch!(request_opts, :headers)})
          Agent.get_and_update(response_agent, fn [response | remaining] -> {response, remaining} end)
        end,
        scheduler: fn delay -> send(parent, {:scheduled, delay}) end,
        clock: Keyword.get(opts, :clock, fn -> @now end),
        retry_delays: Keyword.get(opts, :retry_delays),
        writer: Keyword.get(opts, :writer)
      )

    on_exit(fn -> if Process.alive?(cleanup), do: GenServer.stop(cleanup, :normal) end)
    {:ok, cleanup}
  end

  defp queue_records(root) do
    root
    |> Path.join("provider-cleanup.ndjson")
    |> File.stream!()
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, record} -> [record]
        {:error, _reason} -> []
      end
    end)
    |> Enum.map(& &1["op"])
  end

  defp queue_records_data(root) do
    root
    |> Path.join("provider-cleanup.ndjson")
    |> File.stream!()
    |> Enum.map(fn line -> Jason.decode!(line) end)
  end

  defp advance(time, milliseconds), do: DateTime.add(time, milliseconds, :millisecond)
  defp sync(cleanup), do: :sys.get_state(cleanup)
  defp clock_at(time), do: start_supervised!({Agent, fn -> time end})
  defp clock(clock), do: fn -> Agent.get(clock, & &1) end
  defp advance_clock(clock, milliseconds), do: Agent.update(clock, &advance(&1, milliseconds))

  defp write_record(root, record) do
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    path = Path.join(root, "provider-cleanup.ndjson")
    File.write!(path, Jason.encode!(record) <> "\n", [:append])
    File.chmod!(path, 0o600)
    :ok
  end

  def telemetry_handler(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, event, measurements, metadata})
  end

  # The standalone package cannot depend on Aiur.TestCleanup; its own queue is stopped first.
  defp remove_root!(root), do: File.rm_rf!(root)
end
