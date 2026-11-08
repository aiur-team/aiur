defmodule Aiur.BuildOrder.TicketTimelineProvider do
  @moduledoc "Read durable event pages for the Build ticket lifecycle timeline."

  alias Aiur.BuildOrder.TicketTimelineCache
  alias Aiur.{IssueLog, TrackerIdentity}

  @spec read_page(TrackerIdentity.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_page(%TrackerIdentity{} = identity, opts), do: IssueLog.event_history_page(identity, opts)

  @spec cached(term()) :: map() | nil
  def cached(key), do: TicketTimelineCache.get(key)

  @spec cache(term(), map()) :: :ok
  def cache(key, built), do: TicketTimelineCache.put(key, built)
end
