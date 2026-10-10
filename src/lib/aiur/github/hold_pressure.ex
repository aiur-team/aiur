defmodule Aiur.GitHub.HoldPressure do
  @moduledoc """
  Makes local GitHub budget holds visible as a rate instead of as per-ticket
  alerts (#4067).

  A local hold is the request guard pacing a shared credential before the
  request reaches GitHub; it clears by itself within seconds. One hold says
  nothing, the rate says how hard the fleet is pressing on the pacer. This
  process keeps:

  * holds per resource over the last minute, printed by `aiur status`;
  * consecutive hold-caused dispatch declines per ticket, so a ticket only
    raises an Executor attention once it has been declined
    `agent.dispatch_hold_attention_threshold` times in a row. The run is
    counted, not timed: a hold that never clears escalates at any poll cadence.

  `record/1` runs on the GitHub request path and must never fail a request: it
  casts and swallows a down process.
  """

  use GenServer

  alias Aiur.Config
  alias Aiur.Config.Schema.Agent, as: AgentConfig

  @rate_window_ms 60_000
  @resources ["core", "graphql", "search"]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Counts one local hold against its resource and returns the hold unchanged."
  @spec record(map(), keyword()) :: map()
  def record(hold, opts \\ []) when is_map(hold) and is_list(opts) do
    now_ms = Keyword.get_lazy(opts, :now_ms, &now_ms/0)
    GenServer.cast(Keyword.get(opts, :name, __MODULE__), {:hold, to_string(Map.get(hold, :resource, "core")), now_ms})
    hold
  rescue
    ArgumentError -> hold
  end

  @doc "Holds per resource over the last minute, or `:unavailable` when the monitor is not running."
  @spec per_minute(keyword()) :: %{String.t() => non_neg_integer()} | :unavailable
  def per_minute(opts \\ []) when is_list(opts) do
    GenServer.call(Keyword.get(opts, :name, __MODULE__), {:per_minute, Keyword.get_lazy(opts, :now_ms, &now_ms/0)})
  catch
    :exit, _reason -> :unavailable
  end

  @doc "The `aiur status` line for the hold rate."
  @spec status_line(keyword()) :: String.t()
  def status_line(opts \\ []) when is_list(opts) do
    case per_minute(opts) do
      :unavailable -> "GITHUB HOLDS unavailable"
      rates -> "GITHUB HOLDS " <> Enum.map_join(@resources, " ", &"#{&1}=#{Map.get(rates, &1, 0)}/min")
    end
  end

  @doc """
  Records one hold-caused dispatch decline for `issue_id` and says whether the
  ticket has now been declined often enough in a row to need the Executor.
  `dispatch_cleared/2` ends the run.

  A monitor that is not running answers `:attention`: losing the count must not
  silence a ticket that is genuinely stuck.
  """
  @spec dispatch_decline(term(), keyword()) :: :transient | :attention
  def dispatch_decline(issue_id, opts \\ []) when is_list(opts) do
    GenServer.call(Keyword.get(opts, :name, __MODULE__), {:decline, issue_id, threshold()})
  catch
    :exit, _reason -> :attention
  end

  @doc "Ends `issue_id`'s run of hold-caused declines: its dispatch read got through, or failed for another reason."
  @spec dispatch_cleared(term(), keyword()) :: :ok
  def dispatch_cleared(issue_id, opts \\ []) when is_list(opts) do
    # A call, so a clear from the validation task is ordered before the next decline.
    GenServer.call(Keyword.get(opts, :name, __MODULE__), {:cleared, issue_id})
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{holds: [], declines: %{}}}

  @impl true
  def handle_cast({:hold, resource, now_ms}, state) do
    {:noreply, %{state | holds: [{resource, now_ms} | recent_holds(state.holds, now_ms)]}}
  end

  @impl true
  def handle_call({:per_minute, now_ms}, _from, state) do
    holds = recent_holds(state.holds, now_ms)
    {:reply, Enum.frequencies_by(holds, &elem(&1, 0)), %{state | holds: holds}}
  end

  def handle_call({:cleared, issue_id}, _from, state), do: {:reply, :ok, %{state | declines: Map.delete(state.declines, issue_id)}}

  def handle_call({:decline, issue_id, threshold}, _from, state) do
    count = Map.get(state.declines, issue_id, 0) + 1
    {:reply, if(count >= threshold, do: :attention, else: :transient), %{state | declines: Map.put(state.declines, issue_id, count)}}
  end

  defp recent_holds(holds, now_ms), do: Enum.filter(holds, fn {_resource, at_ms} -> at_ms > now_ms - @rate_window_ms end)

  defp now_ms, do: System.monotonic_time(:millisecond)

  # A config that cannot be read degrades to the schema default rather than
  # crashing the dispatch path that asks.
  defp threshold do
    case Config.settings!().agent.dispatch_hold_attention_threshold do
      value when is_integer(value) and value > 0 -> value
      _invalid -> schema_default()
    end
  rescue
    _error -> schema_default()
  end

  defp schema_default, do: struct!(AgentConfig).dispatch_hold_attention_threshold
end
