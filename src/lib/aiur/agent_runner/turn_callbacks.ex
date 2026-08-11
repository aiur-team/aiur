defmodule Aiur.AgentRunner.TurnCallbacks do
  @moduledoc false

  alias Aiur.AgentRunner.{CheckpointDelivery, MessageHandler, SessionLifecycle}
  alias Aiur.Issue

  @type callbacks :: %{
          on_message: (map() -> :ok),
          on_safe_checkpoint: fun(),
          on_operator_message: fun(),
          live_opts: keyword()
        }

  @spec build(map(), Issue.t(), keyword()) :: callbacks()
  def build(app_session, %Issue{} = issue, opts) when is_map(app_session) and is_list(opts) do
    backend = SessionLifecycle.session_backend!(app_session)
    recipient = Keyword.get(opts, :recipient)
    orchestrator = Keyword.fetch!(opts, :orchestrator)

    live_opts =
      opts
      |> Keyword.put(:backend, backend)
      |> Keyword.put(:live_conversation_recipient, recipient)

    lifecycle_opts =
      live_opts
      |> Keyword.put_new(:attempt_id, Keyword.get(opts, :telemetry_attempt_id))

    on_message =
      MessageHandler.build(
        recipient,
        issue,
        Keyword.get(opts, :workspace),
        Keyword.get(opts, :worker_host),
        backend,
        Keyword.get(opts, :turn_id),
        lifecycle_opts
      )

    %{
      on_message: on_message,
      on_safe_checkpoint:
        CheckpointDelivery.safe_checkpoint_handler(
          issue,
          orchestrator,
          backend,
          Aiur.DecisionStore,
          live_opts
        ),
      on_operator_message:
        CheckpointDelivery.operator_immediate_handler(
          issue,
          orchestrator,
          Aiur.DecisionStore,
          live_opts
        ),
      live_opts: live_opts
    }
  end
end
