defmodule AiurWeb.Build.IndexSource do
  @moduledoc "Build home reads over the shared index; financial values remain per socket."
  @behaviour AiurWeb.Build.DataSource
  alias Aiur.BuildOrder.Index, as: Core
  alias AiurWeb.Build.{Freshness, Index, Usage}
  alias AiurWeb.EndpointConfig

  @impl true
  def subscribe(opts) do
    with :ok <- Keyword.get(opts, :index_subscribe, &Core.subscribe/0).() do
      usage = Keyword.get(opts, :usage, Usage)
      usage.subscribe(Keyword.get(opts, :financial, :locked))
    end
  end

  @impl true
  def snapshot(opts) do
    Process.delete(:build_read_steps)

    with {:ok, data} <- step(:index_window, fn -> window(opts) end) do
      usage = Keyword.get(opts, :usage, Usage)
      freshness = Keyword.get(opts, :freshness, Freshness)

      {:ok,
       Map.merge(data, %{
         usage: step(:usage, fn -> usage.read(Keyword.get(opts, :financial, :locked), opts) end),
         daemon: data.daemon || step(:daemon, fn -> freshness.read_daemon(opts) end),
         writable: EndpointConfig.get(:dashboard_writable) == true
       })}
    end
  end

  defp window(opts), do: guard(fn -> Index.window(server(opts), Keyword.get(opts, :time_zone, "Etc/UTC"), timeout(opts)) end)

  # Read.safe_read reads these timings from the task's dictionary when it hits its cap.
  defp step(name, fun) do
    started = System.monotonic_time(:millisecond)
    Process.put(:build_read_step, name)
    result = fun.()
    Process.put(:build_read_steps, [{name, System.monotonic_time(:millisecond) - started} | Process.get(:build_read_steps, [])])
    result
  end

  @impl true
  def daemon(opts) do
    # ponytail: a mount waits on this call; 1 s caps it, and a busy index falls back to "unknown".
    case guard(fn -> GenServer.call(server(opts), :daemon, 1_000) end) do
      %{} = block -> block
      _ -> nil
    end
  end

  @impl true
  def earlier(before, zone, opts), do: call({:earlier, before, zone, Keyword.get(opts, :days, 1)}, opts)

  @spec ticket(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ticket(id, opts), do: call({:ticket, id}, opts)

  defp call(message, opts), do: guard(fn -> GenServer.call(server(opts), message, timeout(opts)) end)

  defp guard(fun) do
    fun.()
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :index_not_running}
  end

  defp server(opts), do: Keyword.get(opts, :server, Index)
  defp timeout(opts), do: Keyword.get(opts, :timeout, 4_000)
end
