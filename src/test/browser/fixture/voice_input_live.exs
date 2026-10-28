defmodule Aiur.BrowserHarness.VoiceInputLive do
  use Phoenix.LiveView, layout: false

  import AiurWeb.Components.VoiceInput

  @impl true
  def mount(_params, _session, socket) do
    Phoenix.Config.put(AiurWeb.Endpoint, :capabilities_report_fun, fn -> %{capabilities: %{"voice.stt" => %{state: :available}}} end)
    Phoenix.Config.put(AiurWeb.Endpoint, :voice_target_payload_fun, fn -> %{fleet: %{running: [%{issue_identifier: "1110"}]}} end)

    {:ok, assign(socket, draft: "", patch: 0, sent: "", visible: true, capabilities: %{"voice.stt" => %{state: :available}})}
  end

  @impl true
  def handle_event("patch", _params, socket) do
    {:noreply, assign(socket, draft: "server #{socket.assigns.patch + 1}", patch: socket.assigns.patch + 1)}
  end

  def handle_event("send", %{"draft" => draft}, socket), do: {:noreply, assign(socket, :sent, draft)}
  def handle_event("remove", _params, socket), do: {:noreply, assign(socket, :visible, false)}

  @impl true
  def render(assigns) do
    ~H"""
    <main data-voice-fixture data-patch={@patch} data-sent={@sent}>
      <button phx-click="patch">Server patch</button>
      <button phx-click="remove">Remove form</button>
      <form :if={@visible} id="standalone-voice" phx-hook="VoiceInput" phx-submit="send">
        <textarea id="standalone-input" name="draft" aria-label="Draft" data-voice-input>{@draft}</textarea>
        <button type="submit" data-voice-send>Send</button>
        <div id={"standalone-controls-#{@patch}"}>
          <.voice_input id="standalone-controls" legacy_conversation={false} capabilities={@capabilities} target={%{kind: "worker", ticket: "1110"}} />
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
