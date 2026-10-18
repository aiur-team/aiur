defmodule Aiur.BrowserHarness.CommandAnswerLive do
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}

  alias Aiur.BrowserHarness.CommandAnswerFixture
  alias AiurWeb.OperatorControlCenter.DecisionEvents

  @decision_events DecisionEvents.events()

  @impl true
  def mount(%{"decision_id" => decision_id}, _session, socket) do
    {:ok, decision} = CommandAnswerFixture.current(decision_id)

    :ets.insert(
      AiurWeb.EndpointConfig.overrides_table(),
      {{self(), :decision_store}, CommandAnswerFixture.store_name()}
    )

    {:ok,
     socket
     |> Phoenix.Component.assign(:selected_decision, decision)
     |> Phoenix.Component.assign(:selected_decision_id, decision_id)
     |> Phoenix.Component.assign(:decision_actions, %{})}
  end

  @impl true
  def handle_event(event, params, socket) when event in @decision_events do
    {:noreply, DecisionEvents.handle(event, params, socket, &reload/1)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="app-shell">
      <h1>Commands operator answer fixture</h1>
      <p>{@selected_decision.question}</p>
      <form
        id={"decision-answer-form-#{@selected_decision_id}"}
        class="decision-answer-form"
        phx-submit="answer-decision"
      >
        <input type="hidden" name="decision_id" value={@selected_decision_id} />
        <label>
          <input type="radio" name="answer[choice]" value="option:approve" checked />
          Approve
        </label>
        <button type="submit" phx-disable-with="Recording…">Decision</button>
      </form>
    </main>
    """
  end

  defp reload(socket) do
    case CommandAnswerFixture.current(socket.assigns.selected_decision_id) do
      {:ok, decision} -> Phoenix.Component.assign(socket, :selected_decision, decision)
      _ -> socket
    end
  end
end
