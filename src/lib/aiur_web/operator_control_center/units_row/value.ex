defmodule AiurWeb.OperatorControlCenter.UnitsRow.Value do
  @moduledoc false

  @spec get(map() | term(), atom() | String.t()) :: term()
  def get(value, key), do: get(value, key, nil)

  @spec get(map() | term(), atom() | String.t(), term()) :: term()
  def get(%{} = value, key, default), do: Map.get(value, key, Map.get(value, Atom.to_string(key), default))
  def get(_value, _key, default), do: default
end
