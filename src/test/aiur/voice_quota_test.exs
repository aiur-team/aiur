defmodule Aiur.VoiceQuotaTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias Aiur.Voice
  alias AiurWeb.OperatorControlCenter.RunSummaryStrip

  @unconfigured %{state: :unconfigured, window: nil, failure: nil, observed_at: nil}
  @observed %{state: :observed, window: %{used_percent: 10.0, remaining: 90, reset_at: nil}, failure: nil, observed_at: nil}

  defmodule Provider do
    @behaviour Aiur.Voice.Provider
    @impl true
    def transcriber, do: Aiur.VoiceTest.Transcriber
    @impl true
    def synthesizer, do: Aiur.VoiceTest.Synthesizer
    @impl true
    def configured?, do: true
    @impl true
    def child_specs, do: [Aiur.VoiceQuotaTest.Provider]
    @impl true
    def quota_snapshot, do: %{state: :observed, window: %{used_percent: 10.0, remaining: 90, reset_at: nil}, failure: nil, observed_at: nil}
  end

  setup do
    previous = Application.fetch_env(:aiur, :voice_provider)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :voice_provider, value)
        :error -> Application.delete_env(:aiur, :voice_provider)
      end
    end)
  end

  test "child specs and quota observations come from the selected provider" do
    Application.put_env(:aiur, :voice_provider, Provider)
    assert Voice.child_specs() == [Provider]
    assert Voice.quota_snapshot() == @observed
  end

  test "the default provider owns the ElevenLabs quota child" do
    Application.delete_env(:aiur, :voice_provider)
    assert Voice.child_specs() == [Aiur.ElevenLabs.Quota]
  end

  test "an absent or unloadable provider has no child and exactly an unconfigured quota" do
    for provider <- [nil, Aiur.VoiceQuotaTest.Missing] do
      Application.put_env(:aiur, :voice_provider, provider)
      assert Voice.child_specs() == []
      assert Voice.quota_snapshot() == @unconfigured
    end
  end

  test "the ElevenLabs credits row is absent without voice and shows a provider observation" do
    Application.put_env(:aiur, :voice_provider, nil)
    assert Voice.quota_snapshot() == @unconfigured
    refute render_quota() =~ "Credits"

    Application.put_env(:aiur, :voice_provider, Provider)
    assert Voice.quota_snapshot().window.used_percent == 10
    assert render_quota() =~ "Credits"
    assert render_quota() =~ "width:10.0%"
  end

  test "voice children retain the quota boot position and disappear without a provider" do
    Application.delete_env(:aiur, :voice_provider)
    children = children()
    index = Enum.find_index(children, &(&1 == Aiur.GitHub.BudgetBroker))
    assert Enum.at(children, index - 2) == Aiur.GitHub.BrokerTimeout
    assert Enum.at(children, index - 1) == Aiur.GitHub.HoldPressure
    assert Enum.at(children, index + 1) == Aiur.ElevenLabs.Quota

    Application.put_env(:aiur, :voice_provider, Provider)
    assert Enum.at(children(), index + 1) == Provider
    refute Aiur.ElevenLabs.Quota in children()

    Application.put_env(:aiur, :voice_provider, nil)
    refute Aiur.ElevenLabs.Quota in children()
    assert Enum.at(children(), index + 1) == Enum.at(children, index + 2)
  end

  test "the dashboard quota tick reads the selected voice provider" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, elevenlabs_quota: @unconfigured}}
    Application.put_env(:aiur, :voice_provider, Provider)
    assert {:noreply, socket} = AiurWeb.DashboardLive.handle_info(:elevenlabs_quota_tick, socket)
    assert socket.assigns.elevenlabs_quota == @observed

    Application.put_env(:aiur, :voice_provider, nil)
    assert {:noreply, socket} = AiurWeb.DashboardLive.handle_info(:elevenlabs_quota_tick, socket)
    assert socket.assigns.elevenlabs_quota == @unconfigured
  end

  defp children do
    Aiur.Application.child_specs(interactive_cli?: false, headless?: true, dashboard?: false, tailscale_funnel?: false)
  end

  defp render_quota do
    render_component(&RunSummaryStrip.run_summary_strip/1, %{
      run: %{state: :loading},
      usage: %{state: :ready, providers: %{}},
      meters: %{state: :authorized, cards: []},
      elevenlabs_quota: Voice.quota_snapshot(),
      configured_providers: [],
      now: ~U[2026-10-14 00:00:00Z]
    })
  end
end
