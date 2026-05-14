defmodule SymphonyElixir.AgentChat do
  @moduledoc """
  Public facade for operator messages sent to active agent sessions.
  """

  alias SymphonyElixir.Orchestrator

  @spec send(String.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  @spec send(String.t(), String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def send(issue_identifier, text, opts \\ [])
      when is_binary(issue_identifier) and is_binary(text) do
    delivery_policy = Keyword.get(opts, :delivery_policy, :checkpoint)
    fallback = Keyword.get(opts, :fallback)

    Orchestrator.send_operator_message(
      issue_identifier,
      %{kind: :text, body: text, delivery_policy: delivery_policy, fallback: fallback}
    )
  end

  @spec pause(String.t()) :: {:ok, integer()} | {:error, term()}
  def pause(issue_identifier) when is_binary(issue_identifier) do
    Orchestrator.pause_agent(issue_identifier)
  end

  @spec capabilities(String.t()) :: {:ok, map()} | {:error, term()}
  def capabilities(issue_identifier) when is_binary(issue_identifier) do
    Orchestrator.control_capabilities(issue_identifier)
  end
end
