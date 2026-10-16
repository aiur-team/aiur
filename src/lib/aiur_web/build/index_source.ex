defmodule AiurWeb.Build.IndexSource do
  @moduledoc "Build home reads over the shared index; financial values remain per socket."
  @behaviour AiurWeb.Build.DataSource
  alias Aiur.BuildOrder.Index, as: Core
  alias AiurWeb.Build.{Freshness, Index, Usage}
  alias AiurWeb.Endpoint

  @impl true
  def subscribe(opts) do
    with :ok <- Keyword.get(opts, :index_subscribe, &Core.subscribe/0).() do
      usage = Keyword.get(opts, :usage, Usage)
      usage.subscribe(Keyword.get(opts, :financial, :locked))
    end
  end

  @impl true
  def snapshot(opts) do
    with {:ok, data} <- call({:window, Keyword.get(opts, :time_zone, "Etc/UTC")}, opts) do
      usage = Keyword.get(opts, :usage, Usage)
      freshness = Keyword.get(opts, :freshness, Freshness)

      {:ok,
       Map.merge(data, %{
         usage: usage.read(Keyword.get(opts, :financial, :locked), opts),
         daemon: freshness.read_daemon(opts),
         writable: Endpoint.config(:dashboard_writable) == true
       })}
    end
  end

  @impl true
  def earlier(before, zone, opts), do: call({:earlier, before, zone, Keyword.get(opts, :days, 1)}, opts)

  @spec ticket(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ticket(id, opts), do: call({:ticket, id}, opts)

  defp call(message, opts) do
    GenServer.call(Keyword.get(opts, :server, Index), message, Keyword.get(opts, :timeout, 4_000))
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :index_not_running}
  end
end
