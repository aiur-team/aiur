defmodule Aiur.AgentChat do
  @moduledoc """
  Public facade for Executor messages sent to active agent sessions.
  """

  require Logger

  alias Aiur.Opencode.SlotRegistry
  alias Aiur.Orchestrator
  alias Aiur.TrackerIdentity

  @spec send(String.t() | TrackerIdentity.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  @spec send(String.t() | TrackerIdentity.t(), String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def send(target, text, opts \\ [])

  def send(%TrackerIdentity{} = target, text, opts) when is_binary(text),
    do: do_send(target, target.identifier, text, opts)

  def send(issue_identifier, text, opts) when is_binary(issue_identifier) and is_binary(text),
    do: do_send(issue_identifier, issue_identifier, text, opts)

  # `opts[:message_id]` names one user action (#2717). A caller that may retry
  # after a timeout creates it once and passes the same id on its retry, which
  # then returns the first item instead of queueing a copy. Without an id,
  # every send is a new message.
  defp do_send(target, issue_identifier, text, opts) do
    delivery_policy = Keyword.get(opts, :delivery_policy, :interrupt)
    fallback = Keyword.get(opts, :fallback, :queue_next)
    turn_id = Keyword.get(opts, :turn_id)
    message_id = Keyword.get(opts, :message_id)

    Logger.info("AgentChat.send issue=#{issue_identifier} bytes=#{byte_size(text)} body=#{inspect(preview(text))}")

    result =
      Orchestrator.send_operator_message(
        target,
        %{
          kind: :text,
          body: text,
          delivery_policy: delivery_policy,
          fallback: fallback,
          turn_id: turn_id,
          message_id: message_id
        }
      )

    log_send_result(issue_identifier, result)
    result
  end

  # A caller-side timeout is not a failure: the Orchestrator may still queue the
  # message (#2717). It is logged as an unknown outcome, never as failed.
  defp log_send_result(issue_identifier, {:error, {:outcome_unknown, info}}) do
    Logger.warning("AgentChat.send issue=#{issue_identifier} outcome unknown after timeout: #{inspect(info)}")
  end

  defp log_send_result(issue_identifier, {:error, _reason} = result) do
    Logger.warning("AgentChat.send issue=#{issue_identifier} failed: #{inspect(result)}")
  end

  defp log_send_result(_issue_identifier, _result), do: :ok

  defp preview(text) when is_binary(text) do
    if byte_size(text) > 500, do: binary_part(text, 0, 500) <> "…", else: text
  end

  @doc """
  Observe what became of a message `send/3` enqueued.

  `send/3` answers with a queue handle the moment the message is accepted, so
  a successful send proves acceptance only. This is the delivery half of that
  receipt: `:pending` is still queued, `:delivered` was claimed by the agent,
  `:consumed` was acted on.
  """
  @spec delivery_status(integer(), timeout()) ::
          {:ok, Aiur.AgentQueueItem.status()} | {:error, term()}
  def delivery_status(request_id, timeout \\ 5_000) when is_integer(request_id) do
    Orchestrator.operator_message_status(Orchestrator, request_id, timeout)
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

  @spec pause(String.t() | TrackerIdentity.t()) :: {:ok, integer()} | {:error, term()}
  def pause(%TrackerIdentity{} = identity), do: Orchestrator.pause_agent(identity)

  def pause(issue_identifier) when is_binary(issue_identifier) do
    Orchestrator.pause_agent(issue_identifier)
  end

  @spec resume(String.t()) :: {:ok, :resumed | :started | :reactivated} | {:error, term()}
  def resume(issue_identifier) when is_binary(issue_identifier) do
    Orchestrator.resume_agent(issue_identifier)
  end

  @spec resume_with_receipt(String.t()) ::
          {:ok, :resumed | :started | :reactivated | :already_running | :sleeping | {:resumed, pos_integer()}}
          | {:error, term()}
  def resume_with_receipt(issue_identifier) when is_binary(issue_identifier) do
    Orchestrator.resume_agent_with_receipt(issue_identifier)
  end

  @spec prioritize(String.t()) :: {:ok, :prioritized | :already_prioritized} | {:error, term()}
  def prioritize(issue_identifier) when is_binary(issue_identifier) do
    Orchestrator.prioritize_agent(issue_identifier)
  end

  @spec deprioritize(String.t()) :: {:ok, :deprioritized | :already_deprioritized} | {:error, term()}
  def deprioritize(issue_identifier) when is_binary(issue_identifier) do
    Orchestrator.deprioritize_agent(issue_identifier)
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
