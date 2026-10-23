Code.require_file("fixtures/voice_provider.exs", __DIR__)

defmodule AiurWeb.VoiceDictateJoinTest do
  use AiurWeb.StreamdeckChannelCase

  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.{VoiceChannel, VoiceReasonCode, VoiceSessionLimiter, VoiceSocket}
  alias AiurWeb.VoiceChannelTest.FakeVoiceProvider

  setup do
    previous = Application.fetch_env(:aiur, :voice_provider)
    previous_fake = Application.fetch_env(:aiur, FakeVoiceProvider)
    Application.put_env(:aiur, :voice_provider, FakeVoiceProvider)
    Application.put_env(:aiur, FakeVoiceProvider, observer: self())
    previous_resolver = Application.fetch_env(:aiur, :voice_target_resolver)
    Application.put_env(:aiur, :voice_target_resolver, AiurWeb.OperatorControlCenter.VoiceTargetResolver)
    put_endpoint_config(dashboard_writable: true)
    if is_nil(Process.whereis(VoiceSessionLimiter)), do: start_supervised!(VoiceSessionLimiter)

    on_exit(fn ->
      restore_app_env(:voice_provider, previous)
      restore_app_env(FakeVoiceProvider, previous_fake)
      restore_app_env(:voice_target_resolver, previous_resolver)
    end)
  end

  test "joins with an empty payload exactly like voice:dictation" do
    assert {:ok, _reply, joined} = subscribe_and_join(voice_socket(), "voice:dictate", %{})
    fake = joined.assigns.stt.pid
    assert_received {:fake_stt_started, ^fake}
    assert joined.assigns.voice_target == nil
  end

  test "a v1 payload for a running agent joins and records its target" do
    running(["ENG-7"])

    assert {:ok, _reply, joined} = subscribe_and_join(voice_socket(), "voice:dictate", worker_payload("ENG-7"))
    assert joined.assigns.voice_target == %{kind: :worker, ticket: "ENG-7", instance_id: nil}
    assert joined.assigns.voice_surface == "agent_composer"
  end

  test "a v1 worker target that is not running is refused before transcription starts" do
    running(["ENG-8"])

    assert {:error, %{reason_code: "target_not_found", reason: "Agent is no longer running."}} =
             VoiceChannel.join("voice:dictate", worker_payload("ENG-7"), voice_socket())

    refute_received {:fake_stt_started, _pid}
    assert_lease_released()
  end

  test "a malformed payload is invalid and releases its lease" do
    assert {:error, %{reason_code: "invalid_payload", reason: "Voice request is invalid."}} =
             VoiceChannel.join("voice:dictate", %{"v" => 2}, voice_socket())

    refute_received {:fake_stt_started, _pid}
    assert_lease_released()
  end

  test "the voice:dictation alias validates a v1 payload too" do
    running([])

    assert {:error, %{reason_code: "target_not_found"}} =
             subscribe_and_join(voice_socket(), "voice:dictation", worker_payload("ENG-7"))
  end

  test "an executor target is unsupported in this build" do
    payload = %{worker_payload("ENG-7") | "surface" => "executor_composer", "target" => %{"kind" => "executor"}}
    assert {:error, %{reason_code: "unsupported_target"}} = subscribe_and_join(voice_socket(), "voice:dictate", payload)
  end

  test "a socket without dashboard authority is refused as auth_changed" do
    unauthenticated = socket(VoiceSocket, "voice-client", %{})

    for topic <- ["voice:dictate", "voice:dictation"] do
      assert {:error, %{reason: "unauthorized", reason_code: "auth_changed"}} = subscribe_and_join(unauthenticated, topic)
    end
  end

  test "an unknown topic is refused as invalid_payload" do
    assert {:error, %{reason: "invalid_topic", reason_code: "invalid_payload"}} =
             VoiceChannel.join("voice:other", %{}, voice_socket())
  end

  test "voice:conversation keeps ignoring the join payload" do
    assert {:ok, _reply, _joined} = subscribe_and_join(voice_socket(), "voice:conversation", %{"v" => 2})
  end

  # Clients translate and pick retry from the code, so the text must stay
  # unchanged and the code must come from the closed contract set.
  test "every pushed session error carries a reason_code next to the unchanged reason" do
    assert {:ok, _reply, joined} = subscribe_and_join(voice_socket(), "voice:dictate")

    cases = [
      {{:voice_error, %{code: :provider_quota, message: "ElevenLabs quota exhausted"}}, "error", "ElevenLabs quota exhausted", "provider_quota"},
      {{:voice_error, "ElevenLabs quota exhausted"}, "error", "ElevenLabs quota exhausted", "provider_quota"},
      {{:voice_error, "ElevenLabs session time limit reached"}, "error", "ElevenLabs session time limit reached", "session_limit"},
      {{:voice_error, "socket reset"}, "error", "socket reset", "provider_error"},
      {{:voice_error, %{code: :provider_error, message: "socket reset"}}, "error", "socket reset", "provider_error"},
      {{:voice_audio, :error, "Voice playback failed"}, "audio_error", "Voice playback failed", "provider_error"}
    ]

    for {message, event, reason, code} <- cases do
      send(joined.channel_pid, message)
      :sys.get_state(joined.channel_pid)
      assert_push(^event, %{"reason" => ^reason, "reason_code" => ^code})
      assert code in VoiceReasonCode.codes()
    end
  end

  # The per-authority cap is two: a leaked lease would refuse the second join.
  # The refused join ran in the test process, which stays alive, so the
  # limiter's owner monitor cannot release a leaked lease behind our back.
  defp assert_lease_released do
    for _ <- 1..2 do
      assert {:ok, _reply, _joined} = subscribe_and_join(voice_socket(), "voice:dictate")
    end
  end

  defp running(identifiers) do
    payload = %{fleet: %{running: Enum.map(identifiers, &%{issue_identifier: &1})}}
    EndpointStubs.put(voice_target_payload_fun: fn -> payload end)
  end

  defp worker_payload(ticket) do
    %{
      "v" => 1,
      "mode" => "dictate",
      "surface" => "agent_composer",
      "target" => %{"kind" => "worker", "ticket" => ticket},
      "client_session_id" => "client-session-1"
    }
  end

  defp voice_socket do
    {:ok, generation} = FinancialDataAccess.current_configuration_generation()

    socket(VoiceSocket, "voice-dictate", %{
      voice_authority: %{configuration_generation: generation, connection_generation: "voice-dictate"}
    })
  end

  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:aiur, key, value)
  defp restore_app_env(key, :error), do: Application.delete_env(:aiur, key)
end
