defmodule Aiur.Events.DurableConsumer.Source do
  @moduledoc """
  Where a `Aiur.Events.DurableConsumer` reads records from.

  The cursor is a dense, single-writer position (for example an export
  journal's `seq`), never an event id: event ids are not a delivery order, so
  a late lower id would be dropped as a duplicate.
  """

  # aiur:event-bus-boundary-member

  @doc "Live path: send `consumer` `{:durable_record, record}` for each new record."
  @callback subscribe(source_opts :: term(), consumer :: pid()) :: :ok

  @doc "Up to `limit` records with position greater than `after_cursor`, in order."
  @callback replay(source_opts :: term(), after_cursor :: non_neg_integer(), limit :: pos_integer()) ::
              {:ok, [record :: map()]} | {:reset, oldest :: non_neg_integer()} | {:error, term()}

  @callback position(record :: map()) :: non_neg_integer()
end
