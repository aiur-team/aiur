defmodule Aiur.Events.SourcePolicy do
  @moduledoc """
  Source-owned publication policy. Publisher retains gate ordering and calls
  observation before branching, then marks resources only after fan-out.
  An absent policy uses `Aiur.Events.SourcePolicy.Null`.
  """

  @callback self_authored?(String.t(), String.t() | nil, map()) :: boolean()
  @callback already_processed?(keyword()) :: boolean()
  @callback mark_processed(keyword()) :: :ok
  @callback observe(term(), keyword()) :: :ok
end
