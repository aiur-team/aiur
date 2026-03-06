defmodule SymphonyElixir.TrackerConfig do
  @moduledoc """
  Behaviour for tracker-specific configuration modules.
  """

  @callback validate!() :: :ok | {:error, String.t()}
end
