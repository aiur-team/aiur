defmodule Aiur.PaneWarmPool do
  @moduledoc """
  Pre-spawned pool of warm pane workers to mitigate BEAM cold-start.

  Phase 1 ships size 1: the first `open_conversation` claims the warm slot
  and the pool replaces it asynchronously. Second concurrent open is still
  cold-path. Resizing to N is a Phase 2 follow-up if rapid multi-open
  becomes common.

  Scaffold: implementation lands with the conversation pane subcommand.
  """

  @spec claim() :: {:ok, pid()} | {:error, :no_warm_worker}
  def claim, do: {:error, :no_warm_worker}

  @spec warm_count() :: non_neg_integer()
  def warm_count, do: 0
end
