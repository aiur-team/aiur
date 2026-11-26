defmodule Aiur.Events.DurableConsumer.Handler do
  @moduledoc """
  Receives records from a `Aiur.Events.DurableConsumer`. Delivery is
  at-least-once, so `handle_record/2` must be idempotent.
  """

  # aiur:event-bus-boundary-member

  @doc "`{:error, _}` retries the same record; `{:discard, _, _}` advances past a permanent failure."
  @callback handle_record(record :: map(), state :: term()) ::
              {:ok, term()} | {:error, term()} | {:discard, term(), term()}

  @doc "The source no longer holds the cursor's successor; re-read any state built from events."
  @callback handle_reset(oldest :: non_neg_integer(), state :: term()) :: {:ok, term()}

  @doc "Called once per outage, when the source first becomes unavailable."
  @callback handle_unavailable(reason :: term(), state :: term()) :: {:ok, term()}
end
