defmodule AiurWeb.OperatorControlCenter.DecisionEvents do
  @moduledoc """
  Routes dashboard decision events to the OCC3 and OCC8 command adapters.
  """

  alias AiurWeb.OperatorControlCenter.{DecisionCommands, RevisionCommands}
  alias Phoenix.LiveView.Socket

  @events [
    "decision-action-change",
    "answer-decision",
    "retry-decision",
    "decision-revision-change",
    "revise-decision",
    "handle-revision-follow-up"
  ]

  @type reload_fun :: (Socket.t() -> Socket.t())

  @spec events() :: [String.t()]
  def events, do: @events

  @spec handle(String.t(), map(), Socket.t(), reload_fun()) :: Socket.t()
  def handle("decision-action-change", %{"decision_id" => decision_id, "answer" => form}, socket, _reload_fun) do
    DecisionCommands.change(socket, decision_id, form)
  end

  def handle("answer-decision", %{"decision_id" => decision_id, "answer" => form}, socket, reload_fun) do
    DecisionCommands.record_answer(socket, decision_id, form, reload_fun)
  end

  def handle("answer-decision", _params, socket, _reload_fun) do
    DecisionCommands.reject_incomplete(socket)
  end

  def handle(
        "retry-decision",
        %{"decision-id" => decision_id, "action-id" => action_id},
        socket,
        reload_fun
      ) do
    DecisionCommands.retry_delivery(socket, decision_id, action_id, reload_fun)
  end

  def handle("decision-revision-change", %{"decision_id" => decision_id, "revision" => form}, socket, _reload_fun) do
    RevisionCommands.change(socket, decision_id, form)
  end

  def handle("revise-decision", %{"decision_id" => decision_id, "revision" => form}, socket, reload_fun) do
    RevisionCommands.revise(socket, decision_id, form, reload_fun)
  end

  def handle("revise-decision", _params, socket, _reload_fun) do
    RevisionCommands.reject_incomplete(socket)
  end

  def handle(
        "handle-revision-follow-up",
        %{"decision_id" => decision_id, "action_id" => action_id, "follow_up" => form},
        socket,
        reload_fun
      ) do
    RevisionCommands.handle_follow_up(socket, decision_id, action_id, form, reload_fun)
  end

  def handle(event, _params, socket, _reload_fun) when event in @events, do: socket
end
