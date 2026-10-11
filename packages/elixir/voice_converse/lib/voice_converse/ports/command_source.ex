defmodule VoiceConverse.Ports.CommandSource do
  @moduledoc "Optional port: open operator commands (questions the agent is waiting on)."

  @type command :: %{id: term(), version: term(), question: String.t(), options: [term()]}

  @callback open(target :: term()) :: {:ok, [command()]} | {:error, term()}
  @callback answer(target :: term(), id :: term(), choice :: term(), idempotency_key :: String.t()) ::
              :ok | {:error, :stale | term()}
  @callback subscribe(target :: term(), pid()) :: :ok | :unsupported
end
