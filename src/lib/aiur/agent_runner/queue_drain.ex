defmodule Aiur.AgentRunner.QueueDrain do
  @moduledoc """
  Executor queue drain, paused-wait loop, and queue-item turn execution.

  Owns the receive loops that block the runner Task process while paused,
  the claim/dispatch cycle for each queued Executor message or event digest,
  and the exactly-once consume/restore/fail settlement per FI-ORC-072 and
  FI-ORC-073.

  All functions here execute **in the runner Task process** — never wrap them
  in a new process, Task.async, or GenServer; doing so silently loses the
  `:pause_agent` / `:resume_agent` / `:agent_queue_updated` control messages
  that this loop receives.
  """

  require Logger

  alias Aiur.AgentRunner.MessageHandler
  alias Aiur.AgentRunner.QueueTurn
  alias Aiur.AgentRunner.TurnLoop
  alias Aiur.Issue
  alias Aiur.PauseContainment

  @doc false
  @spec drain_operator_messages(map(), Issue.t(), fun(), GenServer.server(), pid() | nil) ::
          :ok | {:error, term()}
  @spec drain_operator_messages(map(), Issue.t(), fun(), GenServer.server(), pid() | nil, keyword()) ::
          :ok | {:error, term()}
  def drain_operator_messages(
        app_session,
        issue,
        message_handler,
        orchestrator,
        codex_update_recipient,
        opts \\ []
      ) do
    receive do
      {:pause_agent, request_id, generation} when is_integer(request_id) and is_integer(generation) ->
        TurnLoop.confirm_pause_containment(app_session)
        Logger.info("Agent already paused for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{request_id}")

        MessageHandler.send_control_state(codex_update_recipient, issue, :paused, %{
          kind: :operator_pause,
          request_id: request_id,
          generation: generation
        })

        wait_for_operator_message(
          app_session,
          issue,
          message_handler,
          orchestrator,
          codex_update_recipient,
          opts
        )

      {:pause_agent, request_id} when is_integer(request_id) ->
        TurnLoop.confirm_pause_containment(app_session)
        Logger.info("Agent already paused for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{request_id}")
        MessageHandler.send_control_state(codex_update_recipient, issue, :paused)

        wait_for_operator_message(
          app_session,
          issue,
          message_handler,
          orchestrator,
          codex_update_recipient,
          opts
        )
    after
      0 ->
        drain_queued_operator_messages(
          app_session,
          issue,
          message_handler,
          orchestrator,
          codex_update_recipient,
          opts
        )
    end
  end

  # Paused state. Wait for an explicit wake signal — a new
  # `:agent_queue_updated` broadcast from the orchestrator, or a
  # `:resume_agent` control message — before touching the Executor
  # queue. Eagerly claiming on entry was a foot-gun: when the Executor
  # paused mid-turn, `restore_delivered_queue_items/2` put the in-flight
  # item back in the queue, and the very next entry to this function
  # would re-claim and re-resume in a tight loop that no amount of
  # repeat pause-key presses could escape.
  @doc false
  @spec wait_for_operator_message(map(), Issue.t(), fun(), GenServer.server(), pid() | nil) ::
          :ok | {:error, term()}
  @spec wait_for_operator_message(map(), Issue.t(), fun(), GenServer.server(), pid() | nil, keyword()) ::
          :ok | {:error, term()}
  def wait_for_operator_message(
        app_session,
        issue,
        message_handler,
        orchestrator,
        codex_update_recipient,
        opts \\ []
      ) do
    receive do
      # Bounded no-op park (`NoopWait`) ran out of time: resume with a normal turn.
      :noop_park_timeout ->
        :ok

      {:agent_queue_updated, issue_identifier, _item_id}
      when issue_identifier == issue.identifier ->
        try_claim_after_queue_update(
          app_session,
          issue,
          message_handler,
          orchestrator,
          codex_update_recipient,
          true,
          opts
        )

      {:agent_queue_updated, issue_identifier, _item_id, deliver_now?}
      when issue_identifier == issue.identifier ->
        try_claim_after_queue_update(
          app_session,
          issue,
          message_handler,
          orchestrator,
          codex_update_recipient,
          deliver_now?,
          opts
        )

      {:pause_agent, request_id, generation} when is_integer(request_id) and is_integer(generation) ->
        TurnLoop.confirm_pause_containment(app_session)
        Logger.info("Agent already paused for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{request_id}")

        MessageHandler.send_control_state(codex_update_recipient, issue, :paused, %{
          kind: :operator_pause,
          request_id: request_id,
          generation: generation
        })

        wait_for_operator_message(
          app_session,
          issue,
          message_handler,
          orchestrator,
          codex_update_recipient,
          opts
        )

      {:pause_agent, request_id} when is_integer(request_id) ->
        TurnLoop.confirm_pause_containment(app_session)
        Logger.info("Agent already paused for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{request_id}")
        MessageHandler.send_control_state(codex_update_recipient, issue, :paused)

        wait_for_operator_message(
          app_session,
          issue,
          message_handler,
          orchestrator,
          codex_update_recipient,
          opts
        )

      {:resume_agent, request_id, generation} when is_integer(request_id) and is_integer(generation) ->
        Logger.info("Resuming paused agent for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{request_id}")

        case apply_resume_control(issue, codex_update_recipient, request_id, generation) do
          :ok ->
            # An explicit resume drains the agent queue so restored items land
            # in the same turn instead of waiting for another checkpoint.
            claim_and_run_or_continue(
              app_session,
              issue,
              message_handler,
              orchestrator,
              codex_update_recipient,
              opts
            )

          {:error, _class} ->
            wait_for_operator_message(
              app_session,
              issue,
              message_handler,
              orchestrator,
              codex_update_recipient,
              opts
            )
        end

      {:resume_agent, request_id} when is_integer(request_id) ->
        Logger.info("Resuming paused agent for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{request_id}")
        _ = PauseContainment.release_target(issue.identifier)
        MessageHandler.send_control_state(codex_update_recipient, issue, :working)

        claim_and_run_or_continue(
          app_session,
          issue,
          message_handler,
          orchestrator,
          codex_update_recipient,
          opts
        )
    end
  end

  @doc false
  @spec apply_resume_control(Issue.t(), pid() | nil, pos_integer(), non_neg_integer(), keyword()) ::
          :ok | {:error, :pause_release_failed}
  def apply_resume_control(issue, recipient, request_id, generation, opts \\ []) do
    release = Keyword.get(opts, :release_pause, &PauseContainment.release_target/1)

    case release.(issue.identifier) do
      :ok ->
        MessageHandler.send_control_state(recipient, issue, :working, %{
          request_id: request_id,
          generation: generation
        })

      _not_released ->
        MessageHandler.send_control_rejection(recipient, issue, request_id, generation, :pause_release_failed)
        {:error, :pause_release_failed}
    end
  end

  @doc false
  @spec claim_after_queue_update(GenServer.server(), String.t(), boolean()) ::
          {:ok, map()} | :empty | :ignored
  def claim_after_queue_update(orchestrator, issue_identifier, true) do
    claim_next_wake_queue_item(orchestrator, issue_identifier)
  end

  def claim_after_queue_update(_orchestrator, _issue_identifier, false), do: :ignored

  @doc false
  @spec claim_next_operator_item(GenServer.server(), String.t()) :: {:ok, map()} | :empty
  def claim_next_operator_item(orchestrator, issue_identifier) when is_binary(issue_identifier) do
    case Aiur.Orchestrator.claim_next_operator_queue_item(orchestrator, issue_identifier) do
      {:ok, item} -> {:ok, item}
      :empty -> :empty
      {:error, _reason} -> :empty
    end
  end

  defp try_claim_after_queue_update(
         app_session,
         issue,
         message_handler,
         orchestrator,
         codex_update_recipient,
         deliver_now?,
         opts
       ) do
    case claim_after_queue_update(orchestrator, issue.identifier, deliver_now?) do
      {:ok, item} ->
        Logger.info("Resuming paused agent for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{item.id}")

        MessageHandler.send_control_state(codex_update_recipient, issue, :working)

        run_operator_turn(
          app_session,
          issue,
          item,
          message_handler,
          orchestrator,
          codex_update_recipient,
          opts
        )

      _empty_or_ignored ->
        wait_for_operator_message(
          app_session,
          issue,
          message_handler,
          orchestrator,
          codex_update_recipient,
          opts
        )
    end
  end

  defp claim_and_run_or_continue(
         app_session,
         issue,
         message_handler,
         orchestrator,
         codex_update_recipient,
         opts
       ) do
    case claim_next_wake_queue_item(orchestrator, issue.identifier) do
      {:ok, item} ->
        run_operator_turn(
          app_session,
          issue,
          item,
          message_handler,
          orchestrator,
          codex_update_recipient,
          opts
        )

      :empty ->
        :ok
    end
  end

  defp drain_queued_operator_messages(
         app_session,
         issue,
         message_handler,
         orchestrator,
         codex_update_recipient,
         opts
       ) do
    case claim_next_queue_item(orchestrator, issue.identifier) do
      {:ok, item} ->
        Logger.info("Delivering queued item to #{Aiur.AgentRunner.issue_context(issue)} request_id=#{item.id} category=#{item.category}")

        QueueTurn.run_queue_item_turn(
          app_session,
          issue,
          item,
          message_handler,
          orchestrator,
          codex_update_recipient,
          opts
        )

      :empty ->
        :ok
    end
  end

  defp claim_next_queue_item(orchestrator, issue_identifier) when is_binary(issue_identifier) do
    case Aiur.Orchestrator.claim_next_queue_item(orchestrator, issue_identifier) do
      {:ok, item} -> {:ok, item}
      :empty -> :empty
      {:error, _reason} -> :empty
    end
  end

  defp claim_next_wake_queue_item(orchestrator, issue_identifier) do
    claim_next_queue_item(orchestrator, issue_identifier)
  end

  defp run_operator_turn(
         app_session,
         issue,
         item,
         message_handler,
         orchestrator,
         codex_update_recipient,
         opts
       ) do
    QueueTurn.run_queue_item_turn(
      app_session,
      issue,
      item,
      message_handler,
      orchestrator,
      codex_update_recipient,
      opts
    )
  end

  @spec queue_item_text(map()) :: String.t()
  defdelegate queue_item_text(item), to: QueueTurn

  @spec prepare_operator_delivery(map(), map(), GenServer.server()) ::
          :ok | {:error, {:retry | :failed, term()}}
  defdelegate prepare_operator_delivery(item, issue, decision_store \\ Aiur.Commands.default_store()), to: Aiur.AgentRunner.DeliveryCorrelation
  @spec record_provider_delivery(map(), map(), GenServer.server()) :: :ok
  defdelegate record_provider_delivery(item, issue, decision_store \\ Aiur.Commands.default_store()), to: Aiur.AgentRunner.DeliveryCorrelation

  @spec acknowledge_provider_delivery(GenServer.server(), map(), map()) ::
          :ok | {:error, term()}
  defdelegate acknowledge_provider_delivery(orchestrator, item, provider_metadata), to: Aiur.AgentRunner.DeliveryCorrelation

  @spec settle_operator_delivery_failure(GenServer.server(), map(), {:retry | :failed, term()}) ::
          :ok | {:error, term()}
  defdelegate settle_operator_delivery_failure(orchestrator, item, outcome), to: Aiur.AgentRunner.DeliveryCorrelation
end
