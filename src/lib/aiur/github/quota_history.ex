defmodule Aiur.GitHub.QuotaHistory do
  @moduledoc """
  A bounded time-series of the GitHub quota meter, sampled on a cadence.

  The sibling of `Aiur.GitHub.CacheHistory`, following its cadence, its ring
  size and its rules. That module samples what the cache *holds*; this one
  samples what the API budget *cost*, so the `/github-cache` page can answer
  "who is spending it" over time and not only at this instant.

  ## Sampling never fetches

  Each sample is `Aiur.GitHub.Quota.snapshot/0`, a `GenServer.call` against a
  meter that is already holding the observations. There is no client, no token
  and no transport in this module's reach; the meter refreshes itself from
  GitHub on its own timer whether or not anybody is looking. So the page's
  central property — viewing never causes a GitHub request — is unchanged by a
  process that periodically reads a meter.

  ## A sample is a measurement, not a promise

  `Aiur.GitHub.QuotaUsage.sample/2` answers `nil` for a meter that has observed
  no window, and this sampler then records nothing. An empty history means "the
  sampler has not observed anything", which the page states in words rather
  than drawing a flat zero line under a budget that may in fact be exhausted.

  ## Bounded and in-memory

  The ring is bounded (one hour at the default cadence), in-memory, and lost on
  restart. That is a real limit on a page about an hourly budget: the ring can
  cover about one window and no more, and the page says so.
  """

  use GenServer

  alias Aiur.GitHub.Quota
  alias Aiur.GitHub.QuotaUsage

  @pubsub Aiur.PubSub
  @topic "github:quota:history"
  @message :quota_history_sampled

  # Matched to `CacheHistory` so the two rings on one page cover the same span
  # and an operator is never comparing a 30-second chart with a 5-minute one.
  @default_interval_ms 30_000
  @default_capacity 120

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "The retained history, oldest first, or `[]` when the sampler is absent."
  @spec samples(GenServer.server()) :: [map()]
  def samples(server \\ __MODULE__) do
    GenServer.call(server, :samples)
  catch
    :exit, _reason -> []
  end

  @doc "Forces one sample now. The boot fill and the test seam."
  @spec sample(GenServer.server()) :: :ok
  def sample(server \\ __MODULE__) do
    GenServer.call(server, :sample)
  catch
    :exit, _reason -> :ok
  end

  @doc "Subscribes the caller to new-sample notifications."
  @spec subscribe() :: :ok
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
    :ok
  rescue
    _unavailable -> :ok
  catch
    :exit, _reason -> :ok
  end

  @doc "Reverses `subscribe/0`."
  @spec unsubscribe() :: :ok
  def unsubscribe do
    Phoenix.PubSub.unsubscribe(@pubsub, @topic)
    :ok
  rescue
    _unavailable -> :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    state = %{
      samples: [],
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      capacity: Keyword.get(opts, :capacity, @default_capacity),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      snapshot_fun: Keyword.get(opts, :snapshot_fun, &default_snapshot/0)
    }

    state =
      case take_sample(state) do
        {:ok, state} -> state
        :unavailable -> state
      end

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:samples, _from, state), do: {:reply, state.samples, state}

  def handle_call(:sample, _from, state) do
    case take_sample(state) do
      {:ok, state} ->
        broadcast(length(state.samples))
        {:reply, :ok, state}

      :unavailable ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:sample, state) do
    case take_sample(state) do
      {:ok, state} ->
        broadcast(length(state.samples))
        schedule(state)
        {:noreply, state}

      :unavailable ->
        # A meter that has observed nothing is a normal state, not an error to
        # retry away from. The ring stops growing until it answers; the cadence
        # continues either way.
        schedule(state)
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The same seam the page and the transport use to find the meter, so a test
  # can point all three at one private meter.
  defp default_snapshot do
    :aiur
    |> Application.get_env(:github_quota_server, Quota)
    |> Quota.snapshot()
  end

  defp take_sample(state) do
    now = state.clock.()

    case QuotaUsage.sample(safe_snapshot(state), now) do
      nil ->
        :unavailable

      sample ->
        samples = (state.samples ++ [sample]) |> Enum.take(-state.capacity)
        {:ok, %{state | samples: samples}}
    end
  end

  defp safe_snapshot(state) do
    state.snapshot_fun.()
  rescue
    _unavailable -> %{}
  catch
    :exit, _reason -> %{}
  end

  defp schedule(%{interval_ms: interval}) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :sample, interval)

  defp schedule(_state), do: :ok

  defp broadcast(count) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {@message, count})
    :ok
  rescue
    _unavailable -> :ok
  catch
    :exit, _reason -> :ok
  end
end
