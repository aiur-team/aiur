defmodule LocalHostTest do
  use ExUnit.Case, async: false
  alias VoiceConverse.{Events, SessionRegistry, TranscriptStore}
  alias VoiceConverse.Testing.FakeProvider

  defmacrop receive_barrier(pattern) do
    vars =
      pattern
      |> Macro.prewalk([], fn
        {skip, _, [_]}, acc when skip in [:^, :@, :quote] ->
          {:ok, acc}

        {skip, _, [_, _]}, acc when skip == :quote ->
          {:ok, acc}

        {:_, _, context}, acc when is_atom(context) ->
          {:ok, acc}

        {name, meta, context}, acc when is_atom(name) and is_atom(context) ->
          {:ok, [{name, meta, context} | acc]}

        node, acc ->
          {node, acc}
      end)
      |> elem(1)
      |> Enum.uniq_by(fn {name, _meta, context} -> {name, context} end)

    generated_vars =
      for {name, meta, context} <- vars, do: {name, [generated: true] ++ meta, context}

    match = quote(do: unquote(pattern) = received)

    quote do
      {received, unquote(vars)} =
        receive do
          unquote(match) -> {received, unquote(generated_vars)}
        end

      received
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "local-host-4092-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "briefing.md"), "# Summary\nBuilding a telescope\n")
    File.write!(Path.join(root, "notes.md"), "Lens specifications")
    previous = Application.get_all_env(:local_host)
    Application.put_env(:local_host, :root, root)
    Application.put_env(:local_host, :port, 0)
    Application.put_env(:local_host, :provider, "fake")
    Application.put_env(:local_host, :llm, "fake")

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:local_host, key, value) end)
      :persistent_term.erase({VoiceConverse.TokenIssuer.Hmac, :secret, LocalHost.Voice})
      VoiceConverse.TestCleanup.rm_rf!(root)
    end)

    start_supervised!({LocalHost.Files, interval: 60_000})
    %{root: root}
  end

  test "real page and socket: briefing, listening, draft, confirmation, one outbox record", %{
    root: root
  } do
    {:ok, config} = LocalHost.voice_config()

    config = %{
      config
      | provider:
          {FakeProvider,
           [open_observer: self(), script: [%Events.ProviderConversationId{id: "test-session"}]]}
    }

    start_supervised!(VoiceConverse.child_spec(config))

    :ok =
      VoiceConverse.TokenIssuer.Hmac.put_secret(LocalHost.Voice, :crypto.strong_rand_bytes(32))

    listener = start_supervised!({Bandit, plug: LocalHost.Router, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)
    Application.put_env(:local_host, :port, port)

    client =
      Port.open(
        {:spawn_executable, System.find_executable("node")},
        [
          :binary,
          :exit_status,
          {:line, 8192},
          args: [Path.join(__DIR__, "client.mjs"), "http://127.0.0.1:#{port}"]
        ]
      )

    on_exit(fn -> if Port.info(client), do: Port.close(client) end)
    receive_barrier({:fake_provider, :open_spec, spec})
    assert spec.context =~ "Building a telescope"
    assert spec.context =~ "Command data unavailable"
    refute Enum.any?(spec.tools, &(&1.name == "list_open_commands"))
    receive_barrier({^client, {:data, {:eol, "LISTENING"}}})
    session = spec.owner
    state = :sys.get_state(session)
    id = state.id
    assert {:ok, ^session} = SessionRegistry.lookup(LocalHost.Voice, id)

    :ok =
      FakeProvider.emit(state.provider_ref, %Events.AgentText{
        turn_id: "brief",
        text: "Building a telescope",
        final?: true
      })

    :ok =
      FakeProvider.emit(
        state.provider_ref,
        %Events.ToolCall{
          call_id: "draft",
          name: "propose_instruction",
          params: %{"text" => "Polish the lens"}
        }
      )

    receive_barrier({^client, {:data, {:eol, "DRAFT " <> draft_id}}})
    refute File.exists?(Path.join(root, "outbox.ndjson"))
    Port.command(client, "confirm #{draft_id}\n")
    receive_barrier({^client, {:data, {:eol, "DELIVERY confirmed"}}})
    Port.command(client, "confirm #{draft_id}\n")
    # Synchronous session call follows the socket acknowledgement above.
    assert {:ok, %{status: :confirmed}} =
             VoiceConverse.confirm_draft(LocalHost.Voice, id, draft_id, origin: :client)

    records =
      root
      |> Path.join("outbox.ndjson")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert [%{"type" => "instruct", "ref" => ^draft_id, "text" => "Polish the lens"}] = records
    Port.command(client, "end\n")
    receive_barrier({^client, {:data, {:eol, "ENDED"}}})
    assert {:ok, transcript, _meta} = TranscriptStore.read(Path.join(root, "transcripts"), id)
    assert Enum.any?(transcript, &(&1["type"] == "session_ended"))
  end

  test "fake session without recording reaches listening within 300 ms and loads no host application",
       %{root: root} do
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", root)
    on_exit(fn -> System.put_env("PATH", previous_path) end)
    assert System.find_executable("claude") == nil
    assert System.find_executable("codex") == nil
    assert :code.which(Aiur.Application) == :non_existing
    refute Enum.any?(Application.loaded_applications(), fn {app, _, _} -> app == :aiur end)
    {:ok, config} = LocalHost.voice_config()
    # Isolate the provider startup budget from the transcript store's host-wide sync(1).
    config = %{config | transcript: :none, transcript_root: nil}
    start_supervised!(VoiceConverse.child_spec(config))
    start = System.monotonic_time(:millisecond)
    assert {:ok, id} = VoiceConverse.start_session(LocalHost.Voice, "local", client: self())
    receive_barrier({:voice_conversation_state, ^id, :listening})
    elapsed = System.monotonic_time(:millisecond) - start
    IO.puts("Fake Converse -> listening: #{elapsed} ms")
    assert elapsed <= 300
    assert :ok = VoiceConverse.end_session(LocalHost.Voice, id, :user_end)
  end

  test "file updates, notes, queued questions and split inbox replies", %{root: root} do
    assert %{fork: :none, ask: true} = LocalHost.AgentChannel.capabilities("local")
    assert {:error, :unsupported} = LocalHost.AgentChannel.fork_query("local", "why?", [])
    assert {:ok, "Lens specifications"} = LocalHost.BriefingSource.details("local", "notes", [])
    :ok = LocalHost.BriefingSource.subscribe("local", self())
    :ok = LocalHost.AgentChannel.subscribe("local", self())
    :ok = LocalHost.Files.poll()

    receive_barrier(
      {:briefing_updated, "local", {:ok, %{summary: %{value: "Building a telescope"}}}}
    )

    File.write!(Path.join(root, "briefing.md"), "# Summary\nTesting optics\n")
    :ok = LocalHost.Files.poll()
    receive_barrier({:briefing_updated, "local", {:ok, %{summary: %{value: "Testing optics"}}}})
    assert {:ok, ref} = LocalHost.AgentChannel.ask("local", "What lens?", make_ref(), [])
    record = root |> Path.join("outbox.ndjson") |> File.read!() |> Jason.decode!()
    assert record == %{"type" => "ask", "target" => "local", "text" => "What lens?", "ref" => ref}
    reply = Jason.encode!(%{target: "local", ref: ref, text: "A glass lens"})
    File.write!(Path.join(root, "inbox.ndjson"), reply)
    :ok = LocalHost.Files.poll()
    refute_received {:agent_reply, ^ref, _text}
    File.write!(Path.join(root, "inbox.ndjson"), "\n", [:append])
    :ok = LocalHost.Files.poll()
    receive_barrier({:agent_reply, ^ref, "A glass lens"})
    :ok = LocalHost.Files.poll()
    refute_received {:agent_reply, ^ref, _text}
  end
end
