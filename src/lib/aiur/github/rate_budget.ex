defmodule Aiur.GitHub.RateBudget do
  @moduledoc """
  Maintains the daemon's shared view of GitHub's primary REST rate budget.

  Observations are advisory: missing or malformed headers never block requests.
  Within a reset window the lowest observed remaining count wins so concurrent,
  out-of-order responses cannot make the budget appear healthier.
  """

  use GenServer

  alias Aiur.GitHub.Transport

  @reserve_floor 100
  @reserve_percent 10
  @reset_margin_ms 1_000
  @max_delay_ms :timer.hours(1)

  @type observation :: %{limit: pos_integer(), remaining: non_neg_integer(), reset_at: pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))

  @spec observe_response(map(), GenServer.server()) :: :ok
  def observe_response(response, server \\ __MODULE__) do
    with %{headers: headers} <- response,
         {:ok, observation} <- parse_headers(headers),
         pid when is_pid(pid) <- GenServer.whereis(server) do
      GenServer.call(pid, {:observe, observation})
    else
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  @spec delay_ms(keyword()) :: non_neg_integer()
  def delay_ms(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    now_seconds = Keyword.get_lazy(opts, :now_seconds, fn -> System.system_time(:second) end)

    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(pid, {:delay_ms, now_seconds})
      _ -> 0
    end
  catch
    :exit, _ -> 0
  end

  @spec parse_headers(list() | map()) :: {:ok, observation()} | :error
  def parse_headers(headers) do
    with {limit, ""} <- parse_integer(Transport.header(headers, "x-ratelimit-limit")),
         {remaining, ""} <- parse_integer(Transport.header(headers, "x-ratelimit-remaining")),
         {reset_at, ""} <- parse_integer(Transport.header(headers, "x-ratelimit-reset")),
         true <- limit > 0 and remaining >= 0 and reset_at > 0 do
      {:ok, %{limit: limit, remaining: remaining, reset_at: reset_at}}
    else
      _ -> :error
    end
  end

  @spec calculate_delay_ms(observation() | nil, integer()) :: non_neg_integer()
  def calculate_delay_ms(nil, _now_seconds), do: 0

  def calculate_delay_ms(%{limit: limit, remaining: remaining, reset_at: reset_at}, now_seconds) do
    reserve = max(@reserve_floor, div(limit * @reserve_percent, 100))

    if remaining <= reserve and reset_at > now_seconds do
      min((reset_at - now_seconds) * 1_000 + @reset_margin_ms, @max_delay_ms)
    else
      0
    end
  end

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call({:observe, incoming}, _from, current) do
    {:reply, :ok, merge_observation(current, incoming)}
  end

  @impl true
  def handle_call({:delay_ms, now_seconds}, _from, observation) do
    delay = calculate_delay_ms(observation, now_seconds)
    next = if observation && observation.reset_at <= now_seconds, do: nil, else: observation
    {:reply, delay, next}
  end

  defp merge_observation(nil, incoming), do: incoming

  defp merge_observation(%{reset_at: current_reset} = current, %{reset_at: incoming_reset})
       when incoming_reset < current_reset,
       do: current

  defp merge_observation(%{reset_at: reset_at} = current, %{reset_at: reset_at} = incoming) do
    if incoming.remaining < current.remaining, do: incoming, else: current
  end

  defp merge_observation(_current, incoming), do: incoming

  defp parse_integer(value) when is_binary(value), do: Integer.parse(value)
  defp parse_integer(value) when is_integer(value), do: {value, ""}
  defp parse_integer(_value), do: :error
end
