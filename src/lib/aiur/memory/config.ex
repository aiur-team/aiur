defmodule Aiur.Memory.Config do
  @moduledoc """
  Memory tracker configuration — no external settings required.
  """

  @behaviour Aiur.TrackerConfig

  @impl Aiur.TrackerConfig
  def validate_settings(_settings), do: :continue

  @impl Aiur.TrackerConfig
  def validate!, do: :ok
end
