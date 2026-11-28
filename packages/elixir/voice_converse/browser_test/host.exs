defmodule VoiceConverse.BrowserTestIssuer do
  @behaviour VoiceConverse.Ports.TokenIssuer
  @impl true
  def issue(_scope, _opts), do: {:error, :unsupported}
  @impl true
  def verify("browser-test-token", "converse", _opts), do: {:ok, %{}}
  def verify(_token, _scope, _opts), do: {:error, :invalid}
end

defmodule VoiceConverse.BrowserTestRouter do
  @behaviour Plug
  import Plug.Conn
  @impl true
  def init(opts), do: opts
  @impl true
  def call(conn, _opts) do
    case conn.request_path do
      "/voice" ->
        VoiceConverse.Transport.WebSock.Plug.call(conn,
          instance: VoiceConverse.BrowserTestInstance,
          token_issuer: VoiceConverse.BrowserTestIssuer
        )

      "/talk.css" ->
        static(conn, "talk.css", "text/css")

      "/voice_converse_client.js" ->
        static(conn, "voice_converse_client.js", "text/javascript")

      "/voice_converse_audio.js" ->
        static(conn, "voice_converse_audio.js", "text/javascript")

      "/voice_converse_status.js" ->
        static(conn, "voice_converse_status.js", "text/javascript")

      "/" ->
        static(conn, "talk.html", "text/html")

      "/talk.html" ->
        static(conn, "talk.html", "text/html")

      _ ->
        send_resp(conn, 404, "Not found")
    end
  end

  defp static(conn, file, content_type) do
    path = Path.join(:code.priv_dir(:voice_converse), "static/#{file}")
    conn |> put_resp_content_type(content_type) |> send_file(200, path)
  end
end

defmodule VoiceConverse.BrowserTestAgent do
  alias VoiceConverse.{Events, Testing.FakeProvider}

  def run do
    receive do
      {:fake_provider, :open_spec, %{owner: session}} ->
        wait_for_subscriber(session, 100)
        state = :sys.get_state(session)

        [
          %Events.UserTranscript{text: "Hello there", final?: true},
          %Events.AgentTextTiming{
            turn_id: "browser-turn",
            text: "Hi",
            chars: [{0, 1}, {200, 1}],
            audio_offset_ms: 0,
            estimated: false
          },
          %Events.AgentAudio{turn_id: "browser-turn", format: :pcm_16000, data_b64: Base.encode64(<<0, 0, 0, 0>>)},
          %Events.AgentText{turn_id: "browser-turn", text: "Hi", final?: true}
        ]
        |> Enum.each(&FakeProvider.emit(state.provider_ref, &1))
    end
  end

  defp wait_for_subscriber(_session, 0), do: raise("browser smoke session did not subscribe")

  defp wait_for_subscriber(session, attempts) when attempts > 0 do
    state = :sys.get_state(session)

    if is_pid(state.provider_ref) and map_size(state.subscribers) > 0 do
      :ok
    else
      Process.sleep(10)
      wait_for_subscriber(session, attempts - 1)
    end
  end
end

alias VoiceConverse.Events
alias VoiceConverse.Testing.{FakeBriefingSource, FakeProvider, StaticCredentials}

root = Path.join(System.tmp_dir!(), "voice-converse-browser-#{System.unique_integer([:positive])}")
File.mkdir_p!(root)
StaticCredentials.put(%{fake: "browser-test"})

observer = spawn(VoiceConverse.BrowserTestAgent, :run, [])

{:ok, config} =
  VoiceConverse.Config.new(
    name: VoiceConverse.BrowserTestInstance,
    provider: {FakeProvider, [open_observer: observer, script: [%Events.ProviderConversationId{id: "browser-provider-session"}]]},
    llm: "browser-test-model",
    cloud_disclosure_accepted: true,
    credentials: StaticCredentials,
    briefing_source: FakeBriefingSource,
    transcript_root: root,
    limits: %{daily_minutes_cap: nil, max_session_seconds: 300}
  )

{:ok, _supervisor} =
  Supervisor.start_link(
    [VoiceConverse.child_spec(config), {Bandit, plug: VoiceConverse.BrowserTestRouter, ip: {127, 0, 0, 1}, port: 4187}],
    strategy: :one_for_one
  )

Process.sleep(:infinity)
