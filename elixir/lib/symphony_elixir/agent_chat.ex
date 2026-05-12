defmodule SymphonyElixir.AgentChat do
  @moduledoc """
  Public facade for operator messages sent to active agent sessions.
  """

  alias SymphonyElixir.Orchestrator

  @spec send(String.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  def send(issue_identifier, text) when is_binary(issue_identifier) and is_binary(text) do
    Orchestrator.send_operator_message(issue_identifier, %{kind: :text, body: text})
  end

  @spec pause(String.t()) :: {:ok, integer()} | {:error, term()}
  def pause(issue_identifier) when is_binary(issue_identifier) do
    Orchestrator.pause_agent(issue_identifier)
  end
end
