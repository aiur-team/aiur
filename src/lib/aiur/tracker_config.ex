defmodule Aiur.TrackerConfig do
  @moduledoc """
  Behaviour for tracker-specific configuration modules.
  """

  @callback validate_settings(map()) :: :continue | :ok | {:error, term()}
  @optional_callbacks validate_settings: 1

  @callback validate!() :: :ok | {:error, String.t()}
end
