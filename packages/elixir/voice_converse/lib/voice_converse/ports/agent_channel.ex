defmodule VoiceConverse.Ports.AgentChannel do
  @moduledoc """
  Optional port: talk to the target agent. Calls return asynchronously; answers and receipts
  arrive as messages to the `subscribe/2` pid.
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
