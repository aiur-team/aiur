defmodule Aiur.BuildOrder.TicketTimelineProvider do
  @moduledoc "Read durable event pages for the Build ticket lifecycle timeline."

  alias Aiur.{IssueLog, TrackerIdentity}

  @spec read_page(TrackerIdentity.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_page(%TrackerIdentity{} = identity, opts), do: IssueLog.event_history_page(identity, opts)
end
