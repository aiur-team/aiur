defmodule Aiur.ViewStateSweepTestSupport do
  @moduledoc false

  # A view-state source is a module the sweep calls `refresh/0` on, registered
  # under its own name — so the stand-ins have to be real modules, not named
  # processes, or the test would not exercise the call the sweep actually makes.
  # Each also answers `demanded?/0`, which the sweep consults before reconciling;
  # the stand-in defaults to demanded so the "every running source is
  # reconciled" tests keep passing, and a test can start one undemanded to
  # assert the sweep skips it. `reseed_demand/0` is the uniform re-seed the
  # sweep calls on every source; the stand-ins are not PubSub-backed, so theirs
  # is a no-op (a `ReseedableSource` below has a real one).
  defmodule Source do
    @moduledoc false
    defmacro __using__(_opts) do
      quote do
        use GenServer

        def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
        def refresh, do: GenServer.cast(__MODULE__, :refresh)
        def calls, do: GenServer.call(__MODULE__, :calls)
        def demanded?, do: GenServer.call(__MODULE__, :demanded?)
        def demander_count, do: GenServer.call(__MODULE__, :demander_count)
        def reseed_demand, do: :ok

        @impl true
        def init(opts), do: {:ok, %{calls: 0, demanders: if(Keyword.get(opts, :demanded, true), do: 1, else: 0)}}

        @impl true
        def handle_call(:calls, _from, state), do: {:reply, state.calls, state}

        def handle_call(:demanded?, _from, state), do: {:reply, state.demanders > 0, state}

        def handle_call(:demander_count, _from, state), do: {:reply, state.demanders, state}

        @impl true
        def handle_cast(:refresh, state), do: {:noreply, %{state | calls: state.calls + 1}}
      end
    end
  end

  defmodule SourceA do
    @moduledoc false
    use Source
  end

  defmodule SourceB do
    @moduledoc false
    use Source
  end

  defmodule SourceAbsent do
    @moduledoc false
    use Source
  end

  # A stand-in whose `reseed_demand/0` restores demand, standing in for the real
  # sources' re-seed from PubSub subscriber presence. It starts undemanded — the
  # post-restart state — and the sweep's re-seed is what brings it back, so the
  # sweep's recovery loop is the thing under test (review finding 3).
  defmodule ReseedableSource do
    @moduledoc false
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def refresh, do: GenServer.cast(__MODULE__, :refresh)
    def calls, do: GenServer.call(__MODULE__, :calls)
    def demanded?, do: GenServer.call(__MODULE__, :demanded?)
    def reseed_demand, do: GenServer.cast(__MODULE__, :reseed_demand)

    @impl true
    def init(_opts), do: {:ok, %{calls: 0, demanders: 0}}

    @impl true
    def handle_call(:calls, _from, state), do: {:reply, state.calls, state}

    def handle_call(:demanded?, _from, state), do: {:reply, state.demanders > 0, state}

    @impl true
    def handle_cast(:refresh, state), do: {:noreply, %{state | calls: state.calls + 1}}

    def handle_cast(:reseed_demand, state), do: {:noreply, %{state | demanders: 1}}
  end

  # A stand-in for a real reconciliation source: on each sweep it reads its whole
  # upstream back and publishes only what nothing has claimed, which is exactly
  # the shape the comment sweep has.
  defmodule RecoveringSource do
    @moduledoc false
    use GenServer

    alias Aiur.GitHub.ResourceStore

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def refresh, do: GenServer.cast(__MODULE__, :refresh)
    def published, do: GenServer.call(__MODULE__, :published)
    def demanded?, do: true
    def reseed_demand, do: :ok

    @impl true
    def init(opts), do: {:ok, %{upstream: Keyword.fetch!(opts, :upstream), published: []}}

    @impl true
    def handle_call(:published, _from, state), do: {:reply, Enum.reverse(state.published), state}

    @impl true
    def handle_cast(:refresh, state) do
      published =
        Enum.reduce(state.upstream, state.published, fn {key, version}, acc ->
          if ResourceStore.claim(key, :poll, version) == :marked, do: [key | acc], else: acc
        end)

      {:noreply, %{state | published: published}}
    end
  end
end
