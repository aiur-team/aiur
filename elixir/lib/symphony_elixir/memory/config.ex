defmodule SymphonyElixir.Memory.Config do
  @moduledoc """
  Memory tracker configuration — no external settings required.
  """

  @behaviour SymphonyElixir.TrackerConfig

  @impl SymphonyElixir.TrackerConfig
  def validate!, do: :ok
end
