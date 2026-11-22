defmodule Aiur.Orchestrator.UnresponsiveWatchdog do
  @moduledoc """
  Watches the orchestrator from outside it. The dispatch-cycle stall alert runs
  inside the orchestrator, so when the orchestrator itself stops answering (a
  status call times out) nothing records where it is stuck (#8051).

  Every `@interval_ms` this process reads the orchestrator's current function,
  stack and message queue. When two samples in a row find it outside its idle
  receive loop with messages waiting, it logs the stack and queue length and
  raises `system.orchestrator.unresponsive` once for the episode. It logs the
  stack again at most once a minute while the episode lasts, and raises the
  `.resolved` alert when the orchestrator is idle again. It only reads process
  info; it never calls the orchestrator.
  """

  use GenServer

  require Logger

  alias Aiur.Signal

  @topic "system.orchestrator.unresponsive"
  @interval_ms 15_000
  @relog_ms 60_000
  @stack_frames 15

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      whereis: Keyword.get(opts, :whereis, fn -> Aiur.Project.whereis(Aiur.Orchestrator) |> GenServer.whereis() end),
      info: Keyword.get(opts, :info, &Process.info/2),
      alert: Keyword.get(opts, :alert, &Signal.alert/2),
      now_ms: Keyword.get(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end),
      previous_busy?: false,
      episode: nil
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:sample, state) do
    state = sample(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec sample(map()) :: map()
  def sample(state) do
    case read(state) do
      {:busy, info} -> busy(state, info)
      :idle -> idle(state)
      :unknown -> state
    end
  end

  defp read(state) do
    with pid when is_pid(pid) <- state.whereis.(),
         info when is_list(info) <- state.info.(pid, [:current_function, :message_queue_len, :current_stacktrace]) do
      if busy?(info), do: {:busy, Map.new(info)}, else: :idle
    else
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  # Idle means parked in the receive loop or with nothing waiting.
  defp busy?(info) do
    queue = Keyword.get(info, :message_queue_len, 0)
    current = Keyword.get(info, :current_function)
    queue > 0 and not match?({:gen_server, :loop, _}, current)
  end

  defp busy(%{previous_busy?: false} = state, _info), do: %{state | previous_busy?: true}

  defp busy(%{episode: nil} = state, info) do
    now = state.now_ms.()
    log(info, "is not answering")

    message =
      "The orchestrator has been busy for over #{div(state.interval_ms, 1000)}s with #{info.message_queue_len} messages waiting, in #{format_mfa(info.current_function)}."

    _ = state.alert.(@topic, message: message, reason: message, needs_attention: true, severity: "warning")
    %{state | episode: %{since_ms: now, logged_ms: now}}
  end

  defp busy(%{episode: episode} = state, info) do
    now = state.now_ms.()

    if now - episode.logged_ms >= @relog_ms do
      log(info, "is still not answering after #{div(now - episode.since_ms, 1000)}s")
      %{state | episode: %{episode | logged_ms: now}}
    else
      state
    end
  end

  defp idle(%{episode: nil} = state), do: %{state | previous_busy?: false}

  defp idle(state) do
    seconds = div(state.now_ms.() - state.episode.since_ms, 1000)
    message = "The orchestrator is answering again after about #{seconds}s."
    _ = state.alert.(@topic <> ".resolved", message: message, reason: message, needs_attention: false, severity: "info")
    %{state | previous_busy?: false, episode: nil}
  end

  defp log(info, what) do
    stack =
      info
      |> Map.get(:current_stacktrace, [])
      |> Enum.take(@stack_frames)
      |> Enum.map_join("\n", &("    " <> Exception.format_stacktrace_entry(&1)))

    Logger.warning("aiur_orchestrator_watchdog orchestrator #{what}: message_queue_len=#{info.message_queue_len} current=#{format_mfa(info.current_function)}\n#{stack}")
  end

  defp format_mfa({module, function, arity}), do: Exception.format_mfa(module, function, arity)
  defp format_mfa(other), do: inspect(other)

  defp schedule(state), do: Process.send_after(self(), :sample, state.interval_ms)
end
