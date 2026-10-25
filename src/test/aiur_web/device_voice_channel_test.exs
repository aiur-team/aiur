Code.require_file("fixtures/voice_provider.exs", __DIR__)

defmodule AiurWeb.DeviceVoiceChannelTest do
  use AiurWeb.StreamdeckChannelCase

  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.{VoiceChannel, VoiceSessionLimiter, VoiceSocket}
  alias AiurWeb.VoiceChannelTest.{FakeSTT, FakeVoiceProvider}

  setup do
    previous = Application.fetch_env(:aiur, :voice_provider)
    previous_fake = Application.fetch_env(:aiur, FakeVoiceProvider)
    previous_resolver = Application.fetch_env(:aiur, :voice_target_resolver)
    Application.put_env(:aiur, :voice_provider, FakeVoiceProvider)
    Application.put_env(:aiur, FakeVoiceProvider, observer: self())
    Application.put_env(:aiur, :voice_target_resolver, AiurWeb.OperatorControlCenter.VoiceTargetResolver)
    put_endpoint_config(dashboard_writable: true)
    if is_nil(Process.whereis(VoiceSessionLimiter)), do: start_supervised!(VoiceSessionLimiter)

    on_exit(fn ->
      restore_app_env(:voice_provider, previous)
      restore_app_env(FakeVoiceProvider, previous_fake)
      restore_app_env(:voice_target_resolver, previous_resolver)
    end)
  end

  # Channel-level authority fixtures only; authenticated ticket/socket coverage
  # must use the MP-N2 store and plug once those predecessors are available.
  test "a device dictation streams provider transcripts and forwards audio" do
    assert {:ok, _reply, joined} = subscribe_and_join(device_socket("phone-1"), VoiceChannel, "voice:dictate")
    transcriber = joined.assigns.stt.pid
    audio = Base.encode64(<<1, 2, 3, 4>>)
    push(joined, "audio", %{"data" => audio})
    :sys.get_state(joined.channel_pid)
    assert FakeSTT.pushes(transcriber) == [audio]
    :ok = FakeSTT.transcript(transcriber, :final, "device dictation")
    :sys.get_state(joined.channel_pid)
    assert_push("transcript", %{"kind" => "final", "text" => "device dictation"})
  end

  test "devices cannot use legacy topics" do
    for topic <- ["voice:dictation", "voice:conversation"] do
      assert {:error, %{reason_code: "invalid_payload"}} = VoiceChannel.join(topic, %{}, device_socket("phone-1"))
    end

    refute_received {:fake_stt_started, _pid}
  end

  test "separate connections share the device cap without consuming another principal's allowance" do
    for _ <- 1..2 do
      assert {:ok, _reply, _joined} = subscribe_and_join(device_socket("phone-1"), VoiceChannel, "voice:dictate")
    end

    assert {:error, %{reason_code: "capacity"}} = subscribe_and_join(device_socket("phone-1"), VoiceChannel, "voice:dictate")
    assert {:ok, _reply, _joined} = subscribe_and_join(device_socket("phone-2"), VoiceChannel, "voice:dictate")
    {:ok, generation} = FinancialDataAccess.current_configuration_generation()
    # A browser authority equal to the raw id must remain separate from the
    # device namespace; using device_id without its prefix fails this join.
    dashboard = socket(VoiceSocket, "dashboard", %{voice_authority: %{configuration_generation: generation, connection_generation: "phone-1"}})
    assert {:ok, _reply, _joined} = subscribe_and_join(dashboard, "voice:dictate")
  end

  test "read-only mode refuses device joins before starting transcription" do
    put_endpoint_config(dashboard_writable: false)
    assert {:error, %{reason_code: "read_only"}} = VoiceChannel.join("voice:dictate", %{}, device_socket("phone-1"))
    refute_received {:fake_stt_started, _pid}
  end

  test "watch attribution uses the phone authority and the same v1 target validation" do
    EndpointStubs.put(voice_target_payload_fun: fn -> %{fleet: %{running: [%{issue_identifier: "ENG-7"}]}} end)
    payload = worker_payload("ENG-7")
    assert {:ok, _reply, joined} = subscribe_and_join(device_socket("phone-1"), VoiceChannel, "voice:dictate", payload)
    assert joined.assigns.voice_target == %{kind: :worker, ticket: "ENG-7", instance_id: nil}
    assert joined.assigns.voice_surface == "agent_composer"
    assert {:error, %{reason_code: "target_not_found"}} = VoiceChannel.join("voice:dictate", worker_payload("ENG-8"), device_socket("phone-1"))
    assert {:error, %{reason_code: "invalid_payload"}} = VoiceChannel.join("voice:dictate", %{"v" => 2}, device_socket("phone-1"))
    assert {:ok, _reply, _joined} = subscribe_and_join(device_socket("phone-1"), VoiceChannel, "voice:dictate", payload)
    assert {:error, %{reason_code: "capacity"}} = subscribe_and_join(device_socket("phone-1"), VoiceChannel, "voice:dictate", payload)
  end

  defp device_socket(device_id) do
    socket(VoiceSocket, "device-#{System.unique_integer([:positive])}", %{voice_authority: %{kind: :device, device_id: device_id}})
  end

  defp worker_payload(ticket) do
    %{
      "v" => 1,
      "mode" => "dictate",
      "surface" => "agent_composer",
      "target" => %{"kind" => "worker", "ticket" => ticket},
      "client_session_id" => "watch-session",
      "client" => %{"kind" => "watch"}
    }
  end

  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:aiur, key, value)
  defp restore_app_env(key, :error), do: Application.delete_env(:aiur, key)
end
