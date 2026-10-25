defmodule Aiur.TestSupport.EndpointStubs do
  @moduledoc """
  Per-test `AiurWeb.Endpoint` stubs (#4908).

  A function or process put into the global `Application.put_env(:aiur,
  AiurWeb.Endpoint, ...)` config is called by every other test that renders a
  dashboard. `put/1` scopes stubs to the calling test process instead:
  `AiurWeb.EndpointConfig.get/2` returns them only there and in processes that
  name the test in `$callers` (its LiveViews, channels and Tasks).
  """

  import ExUnit.Callbacks, only: [on_exit: 2]

  @spec init!() :: atom()
  def init!, do: :ets.new(AiurWeb.EndpointConfig.overrides_table(), [:named_table, :public, :set, read_concurrency: true])

  @doc "Scopes `stubs` to the calling test process until the test exits."
  @spec put(keyword()) :: :ok
  def put(stubs) do
    owner = self()
    table = AiurWeb.EndpointConfig.overrides_table()
    true = :ets.insert(table, for({key, value} <- stubs, do: {{owner, key}, value}))
    on_exit({__MODULE__, owner}, fn -> :ets.match_delete(table, {{owner, :_}, :_}) end)
  end

  @doc """
  Scopes the stub values in `config` (functions and pids) to the calling test
  and returns the rest, which is safe to put in the global endpoint env.
  """
  @spec scope(keyword()) :: keyword()
  def scope(config) do
    {stubs, shared} = Enum.split_with(config, fn {_key, value} -> stub?(value) end)
    # A later shared value replaces this test's earlier stub for the same key.
    for {key, _value} <- shared, do: :ets.delete(AiurWeb.EndpointConfig.overrides_table(), {self(), key})
    put(stubs)
    shared
  end

  @spec stub?(term()) :: boolean()
  def stub?(value), do: is_function(value) or is_pid(value)
end
