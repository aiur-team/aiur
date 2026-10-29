defmodule Aiur.Instance.LeaseStore.Renewal do
  @moduledoc false
  require Logger

  alias Aiur.Instance.LeaseStore

  @spec start(pid(), term(), pos_integer(), pos_integer(), pos_integer(), GenServer.server(), keyword()) :: :ok
  def start(parent, key, interval, ttl_ms, margin_ms, server, opts) do
    monitor = Process.monitor(parent)
    now_fun = Keyword.get(opts, :monotonic_now, fn -> System.monotonic_time(:millisecond) end)

    renew_fun =
      Keyword.get(opts, :renew_fun, fn current_key, current_server, ttl ->
        LeaseStore.renew(current_key, server: current_server, ttl_ms: ttl)
      end)

    renew_loop(%{
      parent: parent,
      monitor: monitor,
      key: key,
      interval: interval,
      ttl_ms: ttl_ms,
      margin_ms: margin_ms,
      server: server,
      renew_fun: renew_fun,
      now_fun: now_fun,
      last_good_ms: now_fun.()
    })
  end

  defp renew_loop(%{parent: parent, monitor: monitor, interval: interval} = renewal) do
    deadline = renewal.last_good_ms + renewal.ttl_ms - renewal.margin_ms
    remaining_ms = deadline - renewal.now_fun.()

    if remaining_ms <= 0 do
      fence(renewal, :deadline)
    else
      receive do
        {:DOWN, ^monitor, :process, ^parent, _reason} ->
          :ok
      after
        min(interval, remaining_ms) ->
          if renewal.now_fun.() >= deadline do
            fence(renewal, :deadline)
          else
            renew_once(renewal)
          end
      end
    end
  end

  defp renew_once(%{key: key, server: server, ttl_ms: ttl, renew_fun: renew_fun} = renewal) do
    deadline = renewal.last_good_ms + renewal.ttl_ms - renewal.margin_ms
    remaining_ms = deadline - renewal.now_fun.()

    if remaining_ms <= 0 do
      fence(renewal, :deadline)
    else
      case bounded_renew(renew_fun, key, server, ttl, remaining_ms) do
        {:return, :ok} ->
          renew_loop(%{renewal | last_good_ms: renewal.now_fun.()})

        {:return, {:error, :lease_lost}} ->
          fence(renewal, :lease_lost)

        {:return, {:error, reason}} ->
          retry_or_fence(renewal, reason)

        {:exit, reason} ->
          retry_or_fence(renewal, reason)

        :timeout ->
          fence(renewal, :deadline)
      end
    end
  end

  defp bounded_renew(renew_fun, key, server, ttl, timeout_ms) do
    parent = self()
    result_ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:return, renew_fun.(key, server, ttl)}
          rescue
            error -> {:exit, error}
          catch
            kind, reason -> {:exit, {kind, reason}}
          end

        send(parent, {result_ref, result})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:exit, reason}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^monitor, :process, ^pid, _reason} -> :ok)
        :timeout
    end
  end

  defp retry_or_fence(renewal, reason) do
    deadline = renewal.last_good_ms + renewal.ttl_ms - renewal.margin_ms
    remaining_ms = deadline - renewal.now_fun.()

    if remaining_ms <= 0 do
      fence(renewal, reason)
    else
      Logger.warning("ticket lease renewal unavailable key=#{renewal.key}: #{inspect(reason)}; worker stops in #{remaining_ms}ms unless renewed")
      renew_loop(renewal)
    end
  end

  defp fence(renewal, reason) do
    Logger.error("ticket lease renewal deadline missed key=#{renewal.key}: #{inspect(reason)}; stopping worker")
    Process.exit(renewal.parent, {:shared_ticket_lease_lost, renewal.key})
  end
end
