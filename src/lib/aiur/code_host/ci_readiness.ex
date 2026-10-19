defmodule Aiur.CodeHost.CiReadiness do
  @moduledoc "Provider contract for advisory repository CI readiness."

  @type result :: map()
  @callback check_fun() :: (keyword() -> {:ok, result()} | {:error, term()})
  @callback readiness_scope(keyword()) :: term()
  @callback cached_result(keyword()) :: result() | :unavailable
  @callback cache_result(result()) :: :ok
  @callback format(result()) :: String.t()
  @callback unavailable(String.t(), term()) :: result()
  @callback error_message(term()) :: String.t()
  @callback retryable_error?(term()) :: boolean()
end
