defmodule Aiur.BrowserHarness.VoiceFixtureLive do
  @moduledoc false
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}

  import Aiur.BrowserHarness.VoiceFixtureData
  alias AiurWeb.OperatorControlCenter.{ConversationDrawer, UnitsPresenter}
  alias AiurWeb.OperatorControlCenter.ConversationDrawer.Presenter, as: ConversationPresenter

  @now ~U[2026-07-17 12:00:00Z]

  @impl true
  def mount(params, _session, socket) do
    Phoenix.Config.put(AiurWeb.Endpoint, :voice_target_payload_fun, fn -> %{fleet: %{running: [%{issue_identifier: "1110"}]}} end)

    {:ok,
     assign(socket,
       row: primary_row(),
       voice_handoff: nil,
       voice_conversation_state: if(params["converse"] == "available", do: :available, else: :unavailable),
       listener_test: params["listener"] == "1",
       writable: AiurWeb.Endpoint.config(:dashboard_writable) == true,
       now: @now,
       conversation_drawer: nil,
       drafts: %{},
       sent_message: nil
     )}
  end

  @impl true
  def handle_event("read-conversation", %{"unit" => token}, socket) do
    row = socket.assigns.row

    if UnitsPresenter.row_token(row) == token do
      drawer = %{origin_id: "voice-conversation-#{token}", row: row, view: ConversationPresenter.present(row, conversation_snapshot())}
      {:noreply, assign(socket, :conversation_drawer, drawer)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close-conversation", _params, socket), do: {:noreply, assign(socket, :conversation_drawer, nil)}
  def handle_event("open-voice-conversation", params, socket), do: {:noreply, assign(socket, :voice_handoff, params)}
  def handle_event("composer-change", %{"message" => message}, socket), do: {:noreply, assign(socket, :drafts, %{"1110" => message})}

  def handle_event("send-operator-message", %{"message" => message}, socket) do
    send(self(), :fixture_agent_voice_partial)
    {:noreply, assign(socket, sent_message: message, drafts: %{"1110" => ""})}
  end

  def handle_event("complete-voice-reply", _params, socket) do
    send(self(), :fixture_agent_voice_reply)
    {:noreply, socket}
  end

  def handle_event("pause-agent", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(event, %{assigns: %{conversation_drawer: %{row: row} = drawer}} = socket)
      when event in [:fixture_agent_voice_partial, :fixture_agent_voice_reply] do
    reply = if event == :fixture_agent_voice_partial, do: :with_partial_reply, else: :with_reply
    {:noreply, assign(socket, :conversation_drawer, %{drawer | view: ConversationPresenter.present(row, conversation_snapshot(reply))})}
  end

  def handle_info(_event, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :token, UnitsPresenter.row_token(assigns.row))

    ~H"""
    <main class="app-shell" data-voice-drawer-fixture="true" data-voice-handoff={Jason.encode!(@voice_handoff)} data-voice-draft={@drafts["1110"] || ""} data-sent-message={@sent_message || ""}>
      <h1 id="voice-title" tabindex="-1">Voice acceptance fixture</h1>
      <button id={"voice-conversation-#{@token}"} type="button" phx-click="read-conversation" phx-value-unit={@token} aria-label="Open chat for its-everdred/aiur #1110">Open conversation</button>
      <button type="button" phx-click="complete-voice-reply">Complete voice reply</button>
      <ConversationDrawer.conversation_drawer
        :if={@conversation_drawer}
        id="voice-fixture-conversation-drawer"
        view={@conversation_drawer.view}
        full_conversation_href={AiurWeb.OperatorControlCenter.ConversationLink.href(@conversation_drawer.row.identity)}
        voice_capabilities={%{"voice.stt" => %{state: :available}, "voice.conversation" => %{state: @voice_conversation_state, reason: :not_installed}}}
        composer={%{target_key: "1110", writable_target?: true, messages: []}}
        writable={if(@listener_test, do: @writable, else: true)}
        listener={if(@listener_test, do: %{requested: :async, effective: :async, version: 2, routing: :listener, unread_count: 2, oldest_unread_at: DateTime.add(@now, -120), observed_at: @now}, else: :unavailable)}
        now={@now}
        drafts={@drafts}
        close_event="close-conversation"
        fallback_focus_id="voice-title"
        origin_id={@conversation_drawer.origin_id}
      />
    </main>
    """
  end
end
