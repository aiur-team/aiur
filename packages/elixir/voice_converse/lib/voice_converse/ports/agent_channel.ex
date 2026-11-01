defmodule VoiceConverse.Ports.AgentChannel do
  @moduledoc """
  Optional port: talk to the target agent. Calls return asynchronously; answers and receipts
  arrive as messages to the `subscribe/2` pid.

  `ask/4` receives a client request reference and returns the delivery reference used in
  `{:receipt, delivery_ref, status}` and `{:agent_reply, delivery_ref, text}` messages. The
  adapter captures the first reply after the question is delivered. `fork_query/3` returns a
  reference used in `{:fork_answer, ref, text, mode, usage}` or `{:fork_failed, ref, reason}`.
  Legacy `{:fork_answer, ref, text}` and `{:fork_error, ref, reason}` are also accepted.
  Usage carries `:session_id` and `:cost_usd` when available; missing cost stays unknown.
  Fork implementations must be read-only and honor `:timeout_ms` (60 seconds),
  `:lock_key` (one per voice session) and `:reply_to` (the session process, not the
  short-lived port caller). They must clean up when the recipient exits.
  A channel with an asynchronous listener may report `listener_mode: :async` in its
  capabilities so the assistant can explain that delivery waits for the agent to read. Set
  `ask: true` when queued asking is available; fork-only channels may answer history questions.
  """

  @type capabilities :: %{required(:fork) => :native | :history_copy | :replay | :none, optional(atom()) => term()}

  @callback ask(target :: term(), question :: String.t(), ref :: term(), opts :: keyword()) ::
              {:ok, delivery_id :: term()} | {:error, term()}
  @callback instruct(target :: term(), text :: String.t(), idempotency_key :: String.t(), opts :: keyword()) ::
              {:ok, delivery_id :: term()} | {:error, term()}
  @callback fork_query(target :: term(), question :: String.t(), opts :: keyword()) ::
              {:ok, ref :: term()} | {:error, :unsupported | term()}
  @callback request_briefing(target :: term(), :refresh | :pause) :: :ok | {:error, term()}
  @callback subscribe(target :: term(), pid()) :: :ok | :unsupported
  @callback capabilities(target :: term()) :: capabilities()

  @optional_callbacks request_briefing: 2
end
