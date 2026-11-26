defmodule Aiur.TicketActivity.ProgressPublisher do
  @moduledoc false
  use GenServer

  alias Aiur.Events

  @debounce_ms 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec publish(String.t(), map(), keyword()) :: :ok
  def publish(identifier, payload, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.cast(server, {:publish, identifier, payload, Keyword.get(opts, :publish_fun, &default_publish/2)})
  end

  @impl true
  def init(opts) do
    {:ok, %{publish_fun: Keyword.get(opts, :publish_fun, &default_publish/2), rows: %{}}}
  end

  @impl true
  def handle_cast({:publish, identifier, payload}, state) do
    now = System.monotonic_time(:millisecond)
    current = Map.get(state.rows, identifier, %{sent: nil, fingerprint: nil, pending: nil, timer: nil})
    fingerprint = {payload[:percent], payload[:step]}

    if fingerprint == current.fingerprint or fingerprint == current.pending do
      {:noreply, state}
    else
      elapsed = if is_integer(current.sent), do: now - current.sent, else: @debounce_ms

      if elapsed >= @debounce_ms do
        state |> send_progress(identifier, payload, fingerprint, current) |> then(&{:noreply, &1})
      else
        timer = current.timer || Process.send_after(self(), {:flush, identifier}, @debounce_ms - elapsed)
        row = %{current | pending: fingerprint, payload: payload, timer: timer}
        {:noreply, put_in(state, [:rows, identifier], row)}
      end
    end
  end

  def handle_cast({:publish, identifier, payload, publish_fun}, state) when is_function(publish_fun, 2) do
    current = state.publish_fun
    state = %{state | publish_fun: publish_fun}
    result = handle_cast({:publish, identifier, payload}, state)

    case result do
      {:noreply, next} -> {:noreply, %{next | publish_fun: current}}
      other -> other
    end
  end

  @impl true
  def handle_info({:flush, identifier}, state) do
    case get_in(state, [:rows, identifier]) do
      %{payload: payload, pending: fingerprint} = row when is_map(payload) ->
        state |> send_progress(identifier, payload, fingerprint, row) |> then(&{:noreply, &1})

      _ ->
        {:noreply, state}
    end
  end

  defp send_progress(state, identifier, payload, fingerprint, row) do
    _ = state.publish_fun.("ticket.#{identifier}.progress", payload)
    put_in(state, [:rows, identifier], %{row | sent: System.monotonic_time(:millisecond), fingerprint: fingerprint, pending: nil, payload: nil, timer: nil})
  end

  defp default_publish(topic, payload), do: Events.publish(topic, payload)
end
