defmodule Aiur.Config.InstanceKey do
  @moduledoc false

  @spec current() :: {:ok, String.t()} | {:error, :instance_key_missing | :instance_key_invalid}
  def current do
    case System.get_env("AIUR_INSTANCE_KEY") do
      key when key in [nil, ""] -> {:error, :instance_key_missing}
      key -> if Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, key), do: {:ok, key}, else: {:error, :instance_key_invalid}
    end
  end
end
