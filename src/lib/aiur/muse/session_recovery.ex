defmodule Aiur.Muse.SessionRecovery do
  @moduledoc """
  Classifies native Muse failures that are safe to retry on a fresh transport.

  A closed port while writing `turn/start` means the request was not sent.
  Exits or timeouts after the write or an accepted receipt leave the turn's
  outcome uncertain, so they must not replay claimed work automatically.
  """

  @spec recoverable?(term()) :: boolean()
  def recoverable?({:turn_start_failed, :port_closed}), do: true
  def recoverable?(_reason), do: false
end
