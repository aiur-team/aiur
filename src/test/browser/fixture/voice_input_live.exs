defmodule Aiur.BrowserHarness.VoiceInputLive do
  use Phoenix.LiveView, layout: false

  import AiurWeb.Components.VoiceInput

  alias Aiur.BrowserHarness.CommandAnswerFixture

  @impl true
  def mount(params, _session, socket) do
    if params["command"] == "true", do: Phoenix.Config.put(AiurWeb.Endpoint, :decision_store, CommandAnswerFixture.store_name())
    Phoenix.Config.put(AiurWeb.Endpoint, :capabilities_report_fun, fn -> %{capabilities: %{"voice.stt" => %{state: :available}}} end)
    Phoenix.Config.put(AiurWeb.Endpoint, :voice_target_payload_fun, fn -> %{fleet: %{running: [%{issue_identifier: "1110"}]}} end)

    {:ok,
     assign(socket,
       delivery: nil,
       draft: "",
       modal_draft: "",
       patch: 0,
       sent: "",
       visible: true,
       capabilities: %{"voice.stt" => %{state: :available}}
     )}
  end

  @impl true
  def handle_event("patch", _params, socket) do
    {:noreply, assign(socket, draft: "server #{socket.assigns.patch + 1}", patch: socket.assigns.patch + 1)}
  end

  def handle_event("send", %{"draft" => draft}, socket), do: {:noreply, assign(socket, sent: draft, delivery: %{state: :harness_queued, message_id: 7})}
  def handle_event("unavailable", _params, socket), do: {:noreply, assign(socket, :capabilities, %{"voice.stt" => %{state: :unavailable, reason: :not_configured}})}
  def handle_event("available", _params, socket), do: {:noreply, assign(socket, :capabilities, %{"voice.stt" => %{state: :available}})}
  def handle_event("remove", _params, socket), do: {:noreply, assign(socket, :visible, false)}
  def handle_event("composer-change", %{"message" => message}, socket), do: {:noreply, assign(socket, :modal_draft, message)}
  def handle_event("send-operator-message", %{"message" => message}, socket), do: {:noreply, assign(socket, :sent, message)}
  def handle_event("close-agent-log", _params, socket), do: {:noreply, assign(socket, :modal, nil)}

  @impl true
  def render(assigns) do
    ~H"""
    <main data-voice-fixture data-patch={@patch} data-sent={@sent}>
      <button phx-click="unavailable">Disable voice</button>
      <button phx-click="available">Enable voice</button>
      <button phx-click="patch">Server patch</button>
      <button phx-click="remove">Remove form</button>
      <form :if={@visible} id="standalone-voice" phx-hook="VoiceInput" phx-submit="send">
        <textarea id="standalone-input" name="draft" aria-label="Draft" data-voice-input>{@draft}</textarea>
        <button type="submit" data-voice-send>Send</button>
        <div id={"standalone-controls-#{@patch}"}>
          <.voice_input delivery={@delivery} id="standalone-controls" legacy_conversation={false} capabilities={@capabilities} target={%{kind: "worker", ticket: "1110"}} />
        </div>
      </form>
      <form id="component-form" phx-submit="send">
        <.voice_input id="component-voice" hook="VoiceInput" legacy_conversation={false} capabilities={@capabilities} target={%{kind: "worker", ticket: "1110"}}>
          <textarea id="component-input" name="draft" aria-label="Component draft" data-voice-input></textarea>
          <button type="submit" data-voice-send>Send component</button>
        </.voice_input>
      </form>
      <div id="missing-input" phx-hook="VoiceInput"><.voice_input id="missing-controls" legacy_conversation={false} capabilities={@capabilities} target={%{kind: "worker", ticket: "1110"}} /></div>
    </main>
    """
  end
end
