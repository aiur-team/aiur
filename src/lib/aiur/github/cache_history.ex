defmodule Aiur.GitHub.CacheHistory do
  @moduledoc """
  A bounded time-series of the GitHub state cache, sampled on a cadence.

  The `/github-cache` page's map layer and cost strip are one snapshot: they say
  what the cache holds *now*, and nothing about how it got here. This process is
  the other half. It samples the same store on a fixed cadence and retains a
  bounded ring of recent state, so an operator can see whether the cache is
  growing, draining, or quietly going stale while nobody is watching.

  ## Sampling never fetches

  Each sample is `Aiur.GitHub.CacheInspector.history_sample/1`, an ETS read.
  There is no client, no token and no transport in this module's reach, so the
  page's central property — viewing never causes a GitHub request — is unchanged
  by a process that periodically looks at the cache. The sampler is the chart's
  writer and nothing else.

  ## A sample is a measurement, not a promise

  When the store is unavailable the sampler records nothing, exactly as the page
  refuses to render "0 entries" as though zero were a measurement. An empty
  history means "the sampler has not observed anything", and the page says so
  rather than drawing a flat zero line.

  ## Bounded and in-memory

  The ring is bounded (one hour at the default cadence), in-memory, and lost on
  restart. History is a live-session feature: charts begin again at boot, which
  is honest about what they cover.

  ## Liveness

  Every sample is broadcast on `Aiur.PubSub` so an open page can redraw without
  polling. Subscribing is fail-open, matching every other read path here: a page
  that cannot subscribe still renders the history it already has.
  """

  use GenServer

  alias Aiur.GitHub.CacheInspector

  @pubsub Aiur.PubSub
  @topic "github:cache:history"
  @message :cache_history_sampled

  # How often a sample is taken. 30 seconds tracks the freshness window (stale
  # at 5 minutes) closely enough to see it cross without a chart that moves
  # every render.
  @default_interval_ms 30_000
  # One hour at the default cadence. Long enough to see a sweep, a wipe, or a
  # slow decay; short enough that the ring stays small and the oldest point is
  # still recent.
  @default_capacity 120

  @type sample :: %{
          t_ms: integer(),
          total: non_neg_integer(),
          with_body: non_neg_integer(),
          bodyless: non_neg_integer(),
          fresh: non_neg_integer(),
          stale: non_neg_integer(),
          expired: non_neg_integer(),
          unknown: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "The retained history, oldest first, or `[]` when the sampler is absent."
  @spec samples(GenServer.server()) :: [sample()]
  def samples(server \\ __MODULE__) do
    GenServer.call(server, :samples)
  catch
    :exit, _reason -> []
  end

  @doc """
  Forces one sample now. The boot fill and the test seam; a page never calls
  this, because the cadence is the sampler's job, not the viewer's.
  """
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
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    capacity = Keyword.get(opts, :capacity, @default_capacity)
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    state = %{samples: [], interval_ms: interval, capacity: capacity, clock: clock}

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
        # A store that is not there is a normal state, not an error to retry
        # away from: the ring simply stops growing until the store answers
        # again. The cadence continues either way.
        schedule(state)
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp take_sample(state) do
    now = state.clock.()

    case CacheInspector.history_sample(now) do
      nil ->
        :unavailable

      sample ->
        samples = (state.samples ++ [sample]) |> Enum.take(-state.capacity)
        {:ok, %{state | samples: samples}}
    end
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
