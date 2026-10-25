defmodule Aiur.TestSupport.WakeInboxAck do
  @moduledoc false
  alias Aiur.Executor.Claims
  alias Aiur.ExecutorWakeInbox

  @spec ack_as_owner([map()], GenServer.server()) :: :ok | {:error, term()}
  def ack_as_owner(records, server \\ ExecutorWakeInbox) do
    {:ok, _claim} = Claims.claim("test-owner")
    ExecutorWakeInbox.acknowledge_as("test-owner", records, server)
  end
end
