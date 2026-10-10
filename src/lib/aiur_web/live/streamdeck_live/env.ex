defmodule AiurWeb.StreamdeckLive.Env do
  @moduledoc """
  Endpoint configuration reads and guarded calls shared by the Stream Deck
  emulator modules. Tests inject their seams through the same endpoint config.
  """

  alias AiurWeb.Endpoint

  @spec safe_call((-> term()), term()) :: term()
  def safe_call(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end

  @spec endpoint_config(atom()) :: term()
  def endpoint_config(key) do
    Endpoint.config(key) || Application.get_env(:aiur, Endpoint, []) |> Keyword.get(key)
  rescue
    _ -> Application.get_env(:aiur, Endpoint, []) |> Keyword.get(key)
  end

  @spec dashboard_writable?() :: boolean()
  def dashboard_writable? do
    Endpoint.config(:dashboard_writable) == true
  rescue
    _ -> false
  end
end
