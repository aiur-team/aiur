defmodule Aiur.Experiments.Auto.WindowManager do
  @moduledoc false
  use GenServer
  require Logger
  alias Aiur.Events
  alias Aiur.Experiments
  alias Aiur.Experiments.Auto.{Notifier, WindowRules}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec truncate(String.t(), DateTime.t(), String.t(), GenServer.server()) :: term()
  def truncate(id, at, reason, server \\ __MODULE__), do: GenServer.call(server, {:truncate, id, at, reason}, 180_000)

  @impl true
  def init(opts) do
    :ok = Events.subscribe("ticket.*.pr.merged")
    :ok = Experiments.subscribe()

    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, 3_600_000),
      debounce_ms: Keyword.get(opts, :debounce_ms, 600_000),
      merge_timer: nil,
      config: Keyword.get(opts, :config),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      samples: Keyword.get(opts, :samples, &sample_status/1),
      notify: Keyword.get(opts, :notify, &Notifier.notify/2)
    }

    if not Keyword.get(opts, :start_paused?, false), do: send(self(), :hourly)
    {:ok, state}
  end

  @impl true
  def handle_call({:truncate, id, at, reason}, _from, state) when is_struct(at, DateTime) and is_binary(reason) do
    result = with {:ok, spec, false} <- Experiments.window_spec(id), do: manage(spec, at, reason, state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:hourly, state) do
    evaluate(state)
    Process.send_after(self(), :hourly, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(:merges, state) do
    evaluate(state)
    {:noreply, %{state | merge_timer: nil}}
  end

  def handle_info({:event, _event}, state) do
    timer = state.merge_timer || Process.send_after(self(), :merges, state.debounce_ms)
    {:noreply, %{state | merge_timer: timer}}
  end

  def handle_info({:experiments_changed, id}, state) when is_binary(id) do
    with {:ok, spec, false} <- Experiments.window_spec(id), do: notify(spec, state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp evaluate(state) do
    case Experiments.list() do
      {:ok, rows} -> Enum.each(rows, &evaluate_one(&1.id, state))
      error -> Logger.warning("experiment window listing failed: #{inspect(error)}")
    end
  end

  defp evaluate_one(id, state) do
    with {:ok, spec, false} <- Experiments.window_spec(id) do
      notify(spec, state)
      if WindowRules.collecting?(spec), do: manage(spec, state.clock.(), nil, state)
    end
  rescue
    error -> Logger.warning("experiment #{id} window evaluation failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("experiment #{id} window evaluation exited: #{inspect(reason)}")
  end

  defp manage(spec, now, truncation, state) do
    samples = if WindowRules.collecting?(spec), do: state.samples.(spec), else: :unavailable
    result = Experiments.manage_window(spec["id"], samples, state.config || config(), now, truncation)

    case result do
      {:ok, updated} -> notify(Experiments.Spec.to_map(updated), state)
      :noop -> :ok
      error -> Logger.warning("experiment #{spec["id"]} window transition failed: #{inspect(error)}")
    end

    result
  end

  defp sample_status(spec), do: sample_status(Experiments, spec)

  defp sample_status(provider, spec) do
    if function_exported?(provider, :sample_status, 1), do: Function.capture(provider, :sample_status, 1).(spec), else: :unavailable
  rescue
    _error -> :unavailable
  catch
    :exit, _reason -> :unavailable
  end

  defp notify(%{"design" => %{"kind" => "before_after"}} = spec, state) do
    event =
      case spec["status"] do
        "active" -> "preregister"
        "report_due" -> "report_due"
        status when status in ~w(abandoned cancelled) -> "cancelled"
        _ -> nil
      end

    if event, do: state.notify.(spec, event)
  end

  defp notify(_spec, _state), do: :ok

  defp config do
    case Aiur.Config.settings() do
      {:ok, %{experiments: %{auto: config}}} -> config
      _unconfigured -> %Aiur.Config.Schema.Experiments.Auto{}
    end
  end
end
