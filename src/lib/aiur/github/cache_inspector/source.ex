defmodule Aiur.GitHub.CacheInspector.Source do
  @moduledoc """
  What the debug page is allowed to read.

  Deliberately tiny, and deliberately incapable. A source can enumerate what is
  already held and say whether it is there at all. It cannot be asked for one
  key, which is what stops a "just fetch this one on a miss" from ever being the
  obvious next change: there is no miss to handle, because there is no lookup.
  """

  @doc "Every entry currently held, in any order."
  @callback entries() :: [map()]

  @doc "False when there is no store to read — cold, unbuilt, or not running."
  @callback available?() :: boolean()
end
