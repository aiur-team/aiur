defmodule A do
  @moduledoc "see #{inspect(B.Internal)}"
  @doc "#{inspect(B.Internal)}"
  @typedoc "#{inspect(B.Internal)}"
end
