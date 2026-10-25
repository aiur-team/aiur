defmodule Aiur.Experiments.Auto.Line do
  @moduledoc false
  @enforce_keys [:source, :key, :at]
  defstruct [:source, :key, :at, :before_floor, :before_window, evidence: %{}]
  @type t :: %__MODULE__{source: atom(), key: String.t(), at: DateTime.t(), evidence: map(), before_floor: DateTime.t() | nil, before_window: {DateTime.t(), DateTime.t()} | nil}
end
