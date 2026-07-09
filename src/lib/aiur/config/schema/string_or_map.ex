defmodule Aiur.Config.Schema.StringOrMap do
  @moduledoc false
  @behaviour Ecto.Type

  @spec type() :: :map
  def type, do: :map

  @spec embed_as(term()) :: :self
  def embed_as(_format), do: :self

  @spec equal?(term(), term()) :: boolean()
  def equal?(left, right), do: left == right

  @spec cast(term()) :: {:ok, String.t() | map()} | :error
  def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
  def cast(_value), do: :error

  @spec load(term()) :: {:ok, String.t() | map()} | :error
  def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
  def load(_value), do: :error

  @spec dump(term()) :: {:ok, String.t() | map()} | :error
  def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
  def dump(_value), do: :error
end
