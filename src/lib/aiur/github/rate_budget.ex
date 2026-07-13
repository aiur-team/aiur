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
          optional(:observed_at_monotonic_ms) => integer(),
          optional(:next_admission_at_monotonic_ms) => integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

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

  @doc "Atomically reserves one background REST-core request or returns its pacing delay."
  @spec acquire_core_request(keyword()) :: :ok | {:defer, pos_integer()}
  def acquire_core_request(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    now_seconds = Keyword.get_lazy(opts, :now_seconds, fn -> System.system_time(:second) end)
    monotonic_ms = Keyword.get_lazy(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)

    try do
      case GenServer.whereis(server) do
        pid when is_pid(pid) ->
          GenServer.call(pid, {:acquire_core_request, now_seconds, monotonic_ms}, 250)

        _ ->
          :ok
      end
    catch
      :exit, _ -> fallback_core_request(server, now_seconds, monotonic_ms)
    end
  end

  @doc "Returns non-secret detail when the REST poll budget is actively pacing requests."
  @spec status(keyword()) :: map() | nil
  def status(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    now_seconds = Keyword.get_lazy(opts, :now_seconds, fn -> System.system_time(:second) end)
    monotonic_ms = Keyword.get_lazy(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)

    with server when is_atom(server) <- server,
         [{:observation, observation}] <- :ets.lookup(server, :observation) do
      normalized_now_seconds = normalized_wall_seconds(observation, now_seconds, monotonic_ms)
      delay_ms = effective_delay_ms(observation, normalized_now_seconds, monotonic_ms)
      status_detail(clear_expired(observation, normalized_now_seconds), delay_ms, normalized_now_seconds)
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
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
  def init(name) when is_atom(name) do
    ^name = :ets.new(name, [:named_table, :set, :public, read_concurrency: true])
    {:ok, nil}
  end

  def init(_name), do: {:ok, nil}

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

    publish_observation(next)
    {:noreply, next}
  end

  @impl true
  def handle_call({:delay_ms, wall_seconds, monotonic_ms}, _from, observation) do
    now_seconds = normalized_wall_seconds(observation, wall_seconds, monotonic_ms)
    observation = clear_expired(observation, now_seconds)
    {delay, next} = schedule_next_admission(observation, now_seconds, monotonic_ms)
    publish_observation(next)
    {:reply, delay, next}
  end

  def handle_call(
        {:acquire_core_request, wall_seconds, monotonic_ms},
        _from,
        observation
      ) do
    now_seconds = normalized_wall_seconds(observation, wall_seconds, monotonic_ms)
    observation = clear_expired(observation, now_seconds)
    {reply, next} = acquire(observation, now_seconds, monotonic_ms)
    publish_observation(next)
    {:reply, reply, next}
  end

  defp merge_observation(nil, incoming), do: incoming

  defp merge_observation(%{reset_at: reset_at} = current, %{reset_at: reset_at} = incoming) do
    if incoming.remaining < current.remaining do
      preserve_admission_deadline(incoming, current)
    else
      current
    end
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

  defp acquire(nil, _now_seconds, _monotonic_ms), do: {:ok, nil}

  defp acquire(observation, now_seconds, monotonic_ms) do
    reserve = reserve(observation.limit)

    cond do
      observation.remaining > reserve ->
        {:ok, reserve_request(observation)}

      observation.remaining == 0 ->
        delay = reset_delay_ms(observation, now_seconds)
        {{:defer, delay}, put_admission_deadline(observation, monotonic_ms + delay)}

      admission_ready?(observation, monotonic_ms) ->
        spacing = request_spacing_ms(observation, now_seconds)

        next =
          observation
          |> reserve_request()
          |> put_admission_deadline(monotonic_ms + spacing)

        {:ok, next}

      true ->
        {delay, next} = schedule_next_admission(observation, now_seconds, monotonic_ms)
        {{:defer, max(delay, 1)}, next}
    end
  end

  defp schedule_next_admission(nil, _now_seconds, _monotonic_ms), do: {0, nil}

  defp schedule_next_admission(observation, now_seconds, monotonic_ms) do
    case effective_delay_ms(observation, now_seconds, monotonic_ms) do
      0 ->
        {0, observation}

      delay ->
        next =
          if Map.has_key?(observation, :next_admission_at_monotonic_ms) do
            observation
          else
            put_admission_deadline(observation, monotonic_ms + delay)
          end

        {delay, next}
    end
  end

  defp effective_delay_ms(nil, _now_seconds, _monotonic_ms), do: 0

  defp effective_delay_ms(observation, now_seconds, monotonic_ms) do
    case Map.get(observation, :next_admission_at_monotonic_ms) do
      deadline when is_integer(deadline) and deadline > monotonic_ms -> deadline - monotonic_ms
      deadline when is_integer(deadline) -> 0
      _ -> calculate_delay_ms(observation, now_seconds)
    end
  end

  defp admission_ready?(observation, monotonic_ms) do
    case Map.get(observation, :next_admission_at_monotonic_ms) do
      deadline when is_integer(deadline) -> deadline <= monotonic_ms
      _ -> false
    end
  end

  defp reserve_request(observation) do
    %{observation | remaining: observation.remaining - 1}
  end

  defp request_spacing_ms(observation, now_seconds) do
    window_ms = max(observation.reset_at - now_seconds, 1) * 1_000
    max(div(window_ms + max(observation.remaining, 1) - 1, max(observation.remaining, 1)), 1)
  end

  defp reset_delay_ms(observation, now_seconds) do
    min(max(observation.reset_at - now_seconds, 0) * 1_000 + @reset_margin_ms, @max_delay_ms)
  end

  defp put_admission_deadline(observation, deadline) do
    Map.put(observation, :next_admission_at_monotonic_ms, deadline)
  end

  defp preserve_admission_deadline(incoming, current) do
    case Map.get(current, :next_admission_at_monotonic_ms) do
      deadline when is_integer(deadline) -> put_admission_deadline(incoming, deadline)
      _ -> incoming
    end
  end

  defp fallback_core_request(server, now_seconds, monotonic_ms) when is_atom(server) do
    case :ets.lookup(server, :observation) do
      [{:observation, observation}] ->
        normalized_now_seconds = normalized_wall_seconds(observation, now_seconds, monotonic_ms)

        case clear_expired(observation, normalized_now_seconds) do
          nil -> :ok
          active -> {:defer, max(calculate_delay_ms(active, normalized_now_seconds), 1_000)}
        end

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp fallback_core_request(_server, _now_seconds, _monotonic_ms), do: :ok

  defp publish_observation(nil) do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) and name != [] -> :ets.delete(name, :observation)
      _ -> :ok
    end
  end

  defp publish_observation(observation) do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) and name != [] -> :ets.insert(name, {:observation, observation})
      _ -> :ok
    end
  end

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

  defp reserve(limit), do: min(max(@reserve_floor, div(limit * @reserve_percent, 100)), limit - 1)

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
