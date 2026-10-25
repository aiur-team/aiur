Code.require_file("fixtures/voice_provider.exs", __DIR__)

defmodule AiurWeb.VoiceAbsentTest do
  use AiurWeb.StreamdeckChannelCase

  alias AiurWeb.VoiceChannelTest.FakeVoiceProvider
  alias AiurWeb.{VoiceSessionLimiter, VoiceSocket}

  @dashboard_reason "Voice input isn't installed in this Aiur. Typed messages work as usual."

  setup do
    previous = Application.fetch_env(:aiur, :voice_provider)
    previous_fake = Application.fetch_env(:aiur, FakeVoiceProvider)
    previous_key = System.get_env("ELEVENLABS_API_KEY")
    Application.put_env(:aiur, :voice_provider, nil)
    System.put_env("ELEVENLABS_API_KEY", "test-key-without-provider")
    put_endpoint_config(dashboard_writable: true)
    if is_nil(Process.whereis(VoiceSessionLimiter)), do: start_supervised!(VoiceSessionLimiter)

    on_exit(fn ->
      restore_app_env(:voice_provider, previous)
      restore_app_env(FakeVoiceProvider, previous_fake)
      if previous_key, do: System.put_env("ELEVENLABS_API_KEY", previous_key), else: System.delete_env("ELEVENLABS_API_KEY")
    end)
  end

  test "absent provider explains dashboard and deck failures even with a key set" do
    assert Aiur.Voice.availability() == %{available: false, reason: :not_installed}
    assert {:error, %{reason: @dashboard_reason}} = subscribe_and_join(voice_socket(), "voice:dictation")
    deck = joined_socket()
    reply = push(deck, "voice_start", %{})
    :sys.get_state(deck.channel_pid)
    assert_reply(reply, :error, %{"reason" => "not_installed"})
    assert StreamdeckProjection.voice() == %{available: false, reason: "Voice isn't installed in this Aiur"}
  end

  test "spoken reply explains a provider removed after transcription" do
    Application.put_env(:aiur, :voice_provider, FakeVoiceProvider)
    Application.put_env(:aiur, FakeVoiceProvider, observer: self())
    assert {:ok, _, joined} = subscribe_and_join(voice_socket(), "voice:conversation")
    send(joined.channel_pid, {:voice_closed})
    :sys.get_state(joined.channel_pid)
    assert_push("stopped", %{})
    Application.put_env(:aiur, :voice_provider, nil)
    push(joined, "speak", %{"text" => "Agent reply"})
    :sys.get_state(joined.channel_pid)
    assert_push("audio_error", %{"reason" => @dashboard_reason})
  end

  # Characterization of V6: typed delivery already works without voice.
  test "typed messages reach the same orchestrator boundary with and without voice" do
    original = Process.whereis(Aiur.Orchestrator)
    if original, do: Process.unregister(Aiur.Orchestrator)
    fake = start_supervised!({__MODULE__.TypedAgent, self()})
    Process.register(fake, Aiur.Orchestrator)

    on_exit(fn ->
      if Process.whereis(Aiur.Orchestrator) == fake, do: Process.unregister(Aiur.Orchestrator)
      if original && Process.alive?(original), do: Process.register(original, Aiur.Orchestrator)
    end)

    for provider <- [FakeVoiceProvider, nil] do
      Application.put_env(:aiur, :voice_provider, provider)
      assert {:ok, 42} = Aiur.AgentChat.send("VOICE-ABSENT", "Typed message", delivery_policy: :checkpoint)
      assert_received {:typed_delivery, "VOICE-ABSENT", %{body: "Typed message", kind: :text, delivery_policy: :checkpoint}}
    end
  end

  defp voice_socket do
    {:ok, generation} = FinancialDataAccess.current_configuration_generation()

    socket(VoiceSocket, "absent-provider", %{
      voice_authority: %{configuration_generation: generation, connection_generation: "absent-provider"}
    })
  end

  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:aiur, key, value)
  defp restore_app_env(key, :error), do: Application.delete_env(:aiur, key)

  defmodule TypedAgent do
    @moduledoc false
    use GenServer
    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)
    @impl true
    def init(observer), do: {:ok, observer}
    @impl true
    def handle_call({:send_operator_message, identifier, payload}, _from, observer) do
      send(observer, {:typed_delivery, identifier, payload})
      {:reply, {:ok, 42}, observer}
    end
  end
end
