defmodule Aiur.GitHub.RateBudget do
  @moduledoc """
  Maintains the daemon's shared view of GitHub's primary REST rate budget.

  Observations are advisory: missing or malformed headers never block requests.
  Within a reset window the lowest observed remaining count wins so concurrent,
  out-of-order responses cannot make the budget appear healthier. A newly
  observed reset window supersedes the prior one by arrival order.
  """

  use GenServer

  alias Aiur.GitHub.Transport

  @reserve_floor 100
  @reserve_percent 10
  @reset_margin_ms 1_000
  @max_delay_ms :timer.hours(1)
  @max_reset_window_seconds :timer.hours(1) |> div(1_000)
  @reset_window_slack_seconds :timer.minutes(5) |> div(1_000)
  @rest_resource "core"

  @type observation :: %{
          required(:limit) => pos_integer(),
          required(:remaining) => non_neg_integer(),
          required(:reset_at) => pos_integer(),
          optional(:observed_at_wall_seconds) => integer(),
          optional(:observed_at_monotonic_ms) => integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))

  @spec observe_response(map(), GenServer.server(), keyword()) :: :ok
  def observe_response(response, server \\ __MODULE__, opts \\ []) do
    with %{headers: headers} <- response,
         pid when is_pid(pid) <- GenServer.whereis(server) do
      observed_at_wall_seconds = Keyword.get_lazy(opts, :now_seconds, fn -> System.system_time(:second) end)
      observed_at_monotonic_ms = Keyword.get_lazy(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)
      GenServer.cast(pid, {:observe, headers, observed_at_wall_seconds, observed_at_monotonic_ms})
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
    monotonic_ms = Keyword.get_lazy(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)

    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(pid, {:delay_ms, now_seconds, monotonic_ms})
      _ -> 0
    end
  catch
    :exit, _ -> 0
  end

  @doc "Returns non-secret detail when the REST poll budget is actively pacing requests."
  @spec status(keyword()) :: map() | nil
  def status(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, 100)
    now_seconds = Keyword.get_lazy(opts, :now_seconds, fn -> System.system_time(:second) end)
    monotonic_ms = Keyword.get_lazy(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)

    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(pid, {:status, now_seconds, monotonic_ms}, timeout)
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  @spec parse_headers(list() | map(), keyword()) :: {:ok, observation()} | :error
  def parse_headers(headers, opts \\ []) do
    now_seconds = Keyword.get_lazy(opts, :now_seconds, fn -> System.system_time(:second) end)

    with {limit, ""} <- parse_integer(Transport.header(headers, "x-ratelimit-limit")),
         {remaining, ""} <- parse_integer(Transport.header(headers, "x-ratelimit-remaining")),
         {reset_at, ""} <- parse_integer(Transport.header(headers, "x-ratelimit-reset")),
         @rest_resource <- Transport.header(headers, "x-ratelimit-resource"),
         true <- valid_observation?(limit, remaining, reset_at, now_seconds) do
      {:ok, %{limit: limit, remaining: remaining, reset_at: reset_at}}
    else
      _ -> :error
    end
  end

  @spec calculate_delay_ms(observation() | nil, integer()) :: non_neg_integer()
  def calculate_delay_ms(nil, _now_seconds), do: 0

  def calculate_delay_ms(%{limit: limit, remaining: remaining, reset_at: reset_at}, now_seconds) do
    reserve = min(max(@reserve_floor, div(limit * @reserve_percent, 100)), limit - 1)

    if remaining <= reserve and reset_at > now_seconds do
      progressive_delay_ms(remaining, reserve, reset_at - now_seconds)
    else
      0
    end
  end

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_cast({:observe, headers, wall_seconds, monotonic_ms}, current) do
    normalized_wall_seconds = normalized_wall_seconds(current, wall_seconds, monotonic_ms)

    next =
      case parse_headers(headers, now_seconds: normalized_wall_seconds) do
        {:ok, incoming} ->
          incoming = Map.merge(incoming, %{observed_at_wall_seconds: normalized_wall_seconds, observed_at_monotonic_ms: monotonic_ms})
          merge_observation(current, incoming)

        :error ->
          current
      end

    {:noreply, next}
  end

  @impl true
  def handle_call({:delay_ms, wall_seconds, monotonic_ms}, _from, observation) do
    now_seconds = normalized_wall_seconds(observation, wall_seconds, monotonic_ms)
    delay = calculate_delay_ms(observation, now_seconds)
    next = clear_expired(observation, now_seconds)
    {:reply, delay, next}
  end

  def handle_call({:status, wall_seconds, monotonic_ms}, _from, observation) do
    now_seconds = normalized_wall_seconds(observation, wall_seconds, monotonic_ms)
    delay_ms = calculate_delay_ms(observation, now_seconds)
    next = clear_expired(observation, now_seconds)
    {:reply, status_detail(next, delay_ms, now_seconds), next}
  end

  defp merge_observation(nil, incoming), do: incoming

  defp merge_observation(%{reset_at: reset_at} = current, %{reset_at: reset_at} = incoming) do
    if incoming.remaining < current.remaining, do: incoming, else: current
  end

  defp merge_observation(_current, incoming), do: incoming

  defp normalized_wall_seconds(
         %{observed_at_wall_seconds: observed_wall, observed_at_monotonic_ms: observed_monotonic},
         wall_seconds,
         monotonic_ms
       )
       when monotonic_ms >= observed_monotonic do
    max(wall_seconds, observed_wall + div(monotonic_ms - observed_monotonic, 1_000))
  end

  defp normalized_wall_seconds(_observation, wall_seconds, _monotonic_ms), do: wall_seconds

  defp clear_expired(%{reset_at: reset_at}, now_seconds) when reset_at <= now_seconds, do: nil
  defp clear_expired(observation, _now_seconds), do: observation

  defp status_detail(nil, _delay_ms, _now_seconds), do: nil
  defp status_detail(_observation, 0, _now_seconds), do: nil

  defp status_detail(observation, delay_ms, now_seconds) do
    %{
      reason: :github_rate_budget,
      delay_ms: delay_ms,
      reset_in_ms: max(observation.reset_at - now_seconds, 0) * 1_000,
      remaining: observation.remaining,
      limit: observation.limit
    }
  end

  defp valid_observation?(limit, remaining, reset_at, now_seconds) do
    max_reset_at = now_seconds + @max_reset_window_seconds + @reset_window_slack_seconds
    limit > 0 and remaining >= 0 and remaining <= limit and reset_at > now_seconds and reset_at <= max_reset_at
  end

  defp progressive_delay_ms(0, _reserve, seconds_until_reset) do
    min(seconds_until_reset * 1_000 + @reset_margin_ms, @max_delay_ms)
  end

  defp progressive_delay_ms(remaining, reserve, seconds_until_reset) do
    depletion = reserve - remaining + 1
    ramp_width = reserve + 1
    delay_ms = div(seconds_until_reset * 1_000 * depletion, ramp_width) + @reset_margin_ms
    min(delay_ms, @max_delay_ms)
  end

  defp parse_integer(value) when is_binary(value), do: Integer.parse(value)
  defp parse_integer(value) when is_integer(value), do: {value, ""}
  defp parse_integer(_value), do: :error
end
