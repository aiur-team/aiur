defmodule Aiur.BuildQueue.AttentionTest do
  use Aiur.TestSupport

  alias Aiur.AlertLedger
  alias Aiur.BuildQueue.{Attention, Store}
  alias Aiur.BuildQueue.Model.{Edge, Latch}
  alias Aiur.Events.Exchange

  @topic "ticket.12.queue.attention.prerequisite_failed"
  @payload %{prerequisite: "12", blocked: ["13", "14"], cause: :not_planned}

  setup do
    previous = Application.fetch_env(:aiur, :decision_state_dir)
    root = Aiur.TestSupport.tmp_root!("queue-attention")
    Application.put_env(:aiur, :decision_state_dir, root)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :decision_state_dir, value)
        :error -> Application.delete_env(:aiur, :decision_state_dir)
      end

      File.rm_rf!(root)
    end)

    :ok = Exchange.subscribe(@topic <> ".#")
    {:ok, document} = Store.load()
    {:ok, document: document, root: root}
  end

  test "open twice emits once and preserves unrelated store records", %{document: document} do
    edge = %Edge{prerequisite: "12", dependent: "13", source: :native}
    other = %Latch{key: {:write_failed, "99"}, opened_at_ms: 1, emitted?: true}
    :ok = Store.save(%{document | edges: [edge], latches: [other]})
    assert :ok = Attention.open(:prerequisite_failed, "12", @payload)
    assert :ok = Attention.open(:prerequisite_failed, "12", @payload)
    assert_receive {:event, %{topic: @topic}}
    refute_received {:event, %{topic: @topic}}
    assert {:ok, %{edges: [^edge], latches: [%Latch{key: {:prerequisite_failed, "12"}, emitted?: true}, ^other]}} = Store.load()
    assert [alert] = alerts(@topic)
    assert alert["needs_attention"] == true
    assert alert["message"] =~ "#12 closed as not planned; #13, #14 wait on it"
  end

  test "a fresh caller with the persisted latch does not re-emit" do
    assert :ok = Attention.open(:prerequisite_failed, "12", @payload)
    assert_receive {:event, %{topic: @topic}}
    assert :ok = Task.async(fn -> Attention.open(:prerequisite_failed, "12", @payload) end) |> Task.await()
    refute_received {:event, %{topic: @topic}}
    assert length(alerts(@topic)) == 1
  end

  test "resolve emits once, clears its latch and permits a later opening" do
    assert :ok = Attention.open(:prerequisite_failed, "12", @payload)
    assert :ok = Attention.resolve(:prerequisite_failed, "12")
    assert :ok = Attention.resolve(:prerequisite_failed, "12")
    topic = @topic <> ".resolved"
    assert_receive {:event, %{topic: ^topic}}
    refute_received {:event, %{topic: ^topic}}
    assert {:ok, %{latches: []}} = Store.load()
    assert [alert] = alerts(topic)
    assert alert["needs_attention"] == false
    assert alert["severity"] == "info"
    assert :ok = Attention.open(:prerequisite_failed, "12", @payload)
    assert length(alerts(@topic)) == 2
  end

  test "ledger failure keeps an un-emitted durable latch for the next reconcile" do
    path = AlertLedger.path()
    File.rm!(path)
    File.mkdir_p!(path)
    assert {:error, _} = Attention.open(:prerequisite_failed, "12", @payload)
    assert {:ok, %{latches: [%Latch{emitted?: false}]}} = Store.load()
    refute_received {:event, %{topic: @topic}}
    File.rmdir!(path)
    assert :ok = Attention.open(:prerequisite_failed, "12", @payload)
    assert_receive {:event, %{topic: @topic}}
    assert {:ok, %{latches: [%Latch{emitted?: true}]}} = Store.load()
    assert length(alerts(@topic)) == 1
  end

  test "publication failure retains a retryable latch until the bus recovers" do
    generator = Process.whereis(Aiur.Events.IdGenerator)
    Process.unregister(Aiur.Events.IdGenerator)

    try do
      assert {:error, {:publication_failed, _}} = Attention.open(:prerequisite_failed, "12", @payload)
      assert {:ok, %{latches: [%Latch{emitted?: false}]}} = Store.load()
      refute_received {:event, %{topic: @topic}}
    after
      Process.register(generator, Aiur.Events.IdGenerator)
    end

    assert :ok = Attention.open(:prerequisite_failed, "12", @payload)
    assert_receive {:event, %{topic: @topic}}
    Process.unregister(Aiur.Events.IdGenerator)

    try do
      assert {:error, {:publication_failed, _}} = Attention.resolve(:prerequisite_failed, "12")
      assert {:ok, %{latches: [%Latch{emitted?: true}]}} = Store.load()
    after
      Process.register(generator, Aiur.Events.IdGenerator)
    end

    assert :ok = Attention.resolve(:prerequisite_failed, "12")
    resolved = @topic <> ".resolved"
    assert_receive {:event, %{topic: ^resolved}}
    assert {:ok, %{latches: []}} = Store.load()
  end

  test "resolution failure keeps the latch and retries when the ledger recovers" do
    assert :ok = Attention.open(:prerequisite_failed, "12", @payload)
    path = AlertLedger.path()
    bytes = File.read!(path)
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, _} = Attention.resolve(:prerequisite_failed, "12")
    assert {:ok, %{latches: [%Latch{emitted?: true}]}} = Store.load()
    File.rmdir!(path)
    File.write!(path, bytes)
    assert :ok = Attention.resolve(:prerequisite_failed, "12")
    assert {:ok, %{latches: []}} = Store.load()
  end

  test "unavailable store emits nothing and preserves the corrupt data", %{root: root} do
    path = Path.join([root, "build-queue", "queue.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "broken")
    assert {:error, {:read_failed, _}} = Attention.open(:prerequisite_failed, "12", @payload)
    assert File.read!(path) == "broken"
    refute_received {:event, %{topic: @topic}}
    assert alerts(@topic) == []
  end

  test "only allowlisted refs and attrs reach the bus; copy remains local" do
    payload = Map.merge(@payload, %{message: "private", body: "secret", source: :agent})
    assert :ok = Attention.open(:prerequisite_failed, "12", payload)
    assert_receive {:event, event}
    assert event.topic == @topic
    assert Map.take(event, Map.keys(payload)) == @payload
    refute Map.has_key?(event, "message")
    refute Map.has_key?(event, "reason")
    assert [alert] = alerts(@topic)
    assert alert["message"] =~ "Re-plan or remove"
  end

  test "blocked queue subjects reach the Executor even outside the dispatch tracked set" do
    previous = :persistent_term.get({Aiur.Events.Publisher, :tracked_fn}, nil)

    on_exit(fn ->
      if previous, do: Aiur.Events.Publisher.set_tracked_fn(previous), else: :persistent_term.erase({Aiur.Events.Publisher, :tracked_fn})
    end)

    Aiur.Events.Publisher.set_tracked_fn(fn _ -> false end)
    assert :ok = Attention.open(:prerequisite_failed, "12", @payload)
    assert_receive {:event, %{topic: @topic}}
    assert :ok = Attention.resolve(:prerequisite_failed, "12")
    resolved = @topic <> ".resolved"
    assert_receive {:event, %{topic: ^resolved}}
  end

  test "invalid subjects, causes and payload values cannot create an attention" do
    for {cause, subject, payload} <- [
          {:prerequisite_failed, "12.*", @payload},
          {:unknown, "12", @payload},
          {:inputs_unavailable, "12", %{}},
          {:write_failed, nil, %{}},
          {:prerequisite_failed, "12", %{blocked: ["secret"]}},
          {:prerequisite_failed, "12", %{cause: "private text"}}
        ] do
      assert {:error, :invalid_attention} = Attention.open(cause, subject, payload)
    end

    assert {:ok, %{latches: []}} = Store.load()
    assert alerts(@topic) == []
  end

  test "system attentions use the system scope and also resolve once" do
    topic = "system.queue.attention.inputs_unavailable"
    :ok = Exchange.subscribe(topic <> ".#")
    assert :ok = Attention.open(:inputs_unavailable, nil, %{freshness: :unknown})
    assert :ok = Attention.open(:inputs_unavailable, nil, %{freshness: :unknown})
    assert_receive {:event, %{topic: ^topic, freshness: :unknown}}
    refute_received {:event, %{topic: ^topic}}
    assert :ok = Attention.resolve(:inputs_unavailable, nil)
    assert :ok = Attention.resolve(:inputs_unavailable, nil)
    assert length(alerts(topic <> ".resolved")) == 1
  end

  defp alerts(topic), do: AlertLedger.read(AlertLedger.path()) |> Enum.filter(&(&1["topic"] == topic))
end
