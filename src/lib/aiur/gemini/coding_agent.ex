defmodule Aiur.Gemini.CodingAgent do
  @moduledoc "Native Gemini CLI ACP adapter for Aiur's agent lifecycle."
  @behaviour Aiur.CodingAgent.Backend

  alias Aiur.Gemini.{Session, Turn}

  @impl true
  defdelegate start_session(workspace, opts), to: Session, as: :start

  @impl true
  defdelegate run_turn(session, prompt, issue, opts), to: Turn, as: :run

  @impl true
  defdelegate stop_session(session), to: Session, as: :stop

  @impl true
  def normalize_event(event), do: event

  @impl true
  def send_operator_message(_session, _message), do: {:error, :gemini_messages_require_queued_turn}
end
