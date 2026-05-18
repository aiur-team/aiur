defmodule Aiur.AgentChat do
  @moduledoc """
  Public facade for operator messages sent to active agent sessions.
  """

  require Logger

  alias Aiur.{AgentEvents, AgentPubSub, Orchestrator}

  @spec send(String.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  @spec send(String.t(), String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def send(issue_identifier, text, opts \\ [])
      when is_binary(issue_identifier) and is_binary(text) do
    delivery_policy = Keyword.get(opts, :delivery_policy, :interrupt)
    fallback = Keyword.get(opts, :fallback, :queue_next)

    Logger.info("AgentChat.send issue=#{issue_identifier} bytes=#{byte_size(text)} body=#{inspect(preview(text))}")

    result =
      Orchestrator.send_operator_message(
        issue_identifier,
        %{kind: :text, body: text, delivery_policy: delivery_policy, fallback: fallback}
      )

    case result do
      {:ok, _} = ok ->
        AgentPubSub.broadcast_transcript(
          issue_identifier,
          AgentEvents.transcript_event(:user, text)
        )

        ok

      other ->
        Logger.warning("AgentChat.send issue=#{issue_identifier} failed: #{inspect(other)}")
        other
    end
  end

  defp preview(text) when is_binary(text) do
    if byte_size(text) > 500, do: binary_part(text, 0, 500) <> "…", else: text
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
