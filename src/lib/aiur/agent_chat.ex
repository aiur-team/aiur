defmodule Aiur.AgentChat do
  @moduledoc """
  Public facade for Executor messages sent to active agent sessions.
  """

  require Logger

  alias Aiur.{AgentEvents, AgentPubSub, OperatorWaitLog, Orchestrator}
  alias Aiur.Opencode.SlotRegistry

  @spec send(String.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  @spec send(String.t(), String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def send(issue_identifier, text, opts \\ [])
      when is_binary(issue_identifier) and is_binary(text) do
    delivery_policy = Keyword.get(opts, :delivery_policy, :interrupt)
    fallback = Keyword.get(opts, :fallback, :queue_next)
    turn_id = Keyword.get(opts, :turn_id)

    Logger.info("AgentChat.send issue=#{issue_identifier} bytes=#{byte_size(text)} body=#{inspect(preview(text))}")

    result =
      Orchestrator.send_operator_message(
        issue_identifier,
        %{kind: :text, body: text, delivery_policy: delivery_policy, fallback: fallback, turn_id: turn_id}
      )

    case result do
      {:ok, request_id} = ok ->
        OperatorWaitLog.record_queued(request_id, issue_identifier, byte_size(text))

        AgentPubSub.broadcast_transcript(
          issue_identifier,
          AgentEvents.transcript_event(:user, text, turn_id: turn_id)
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

  @spec interrupt(String.t()) :: :ok | {:error, term()}
  def interrupt(issue_identifier) when is_binary(issue_identifier) do
    Orchestrator.interrupt_agent(issue_identifier)
  end

  @spec pane_interrupt(String.t()) ::
          {:ok, :interrupted | :pause_requested | :paused | :close_pane | :send_interrupt} | {:error, term()}
  def pane_interrupt(pane_id) when is_binary(pane_id) do
    {via, result} =
      case SlotRegistry.find_by_pane_id(pane_id) do
        {:ok, _slot_index, issue_identifier} ->
          {{:slot, issue_identifier}, Orchestrator.pane_interrupt(issue_identifier)}

        :not_found ->
          {:pane_id, Orchestrator.pane_interrupt_by_pane_id(pane_id)}
      end

    Logger.info("aiur_ctrlc bridge pane_id=#{pane_id} via=#{inspect(via)} result=#{inspect(result)}")

    result
  end

  @spec pause(String.t()) :: {:ok, integer()} | {:error, term()}
  def pause(issue_identifier) when is_binary(issue_identifier) do
    Orchestrator.pause_agent(issue_identifier)
  end

  @spec resume(String.t()) :: {:ok, :resumed | :started} | {:error, term()}
  def resume(issue_identifier) when is_binary(issue_identifier) do
    Orchestrator.resume_agent(issue_identifier)
  end

  @spec request_control(String.t(), :pause | :resume, pos_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def request_control(issue_identifier, action, request_id)
      when is_binary(issue_identifier) and action in [:pause, :resume] and is_integer(request_id) and request_id > 0 do
    Orchestrator.request_control(issue_identifier, action, request_id)
  end

  @spec capabilities(String.t()) :: {:ok, map()} | {:error, term()}
  def capabilities(issue_identifier) when is_binary(issue_identifier) do
    Orchestrator.control_capabilities(issue_identifier)
  end

  @spec control_lifecycle(String.t()) :: {:ok, map()} | {:error, term()}
  def control_lifecycle(issue_identifier) when is_binary(issue_identifier) do
    Orchestrator.control_lifecycle(issue_identifier)
  end
end
