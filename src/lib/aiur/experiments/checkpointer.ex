defmodule Aiur.Experiments.Checkpointer do
  @moduledoc "Periodically checkpoints active experiment windows through their single writer."
  use Aiur.PeriodicWorker
  require Logger

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, interval()),
      start_paused?: Keyword.get(opts, :start_paused?, false),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      list: Keyword.get(opts, :list, &Aiur.Experiments.list/1),
      checkpoint: Keyword.get(opts, :checkpoint, &Aiur.Experiments.checkpoint/2)
    }

    {:ok, Aiur.PeriodicWorker.schedule_first_tick(state)}
  end

  @impl Aiur.PeriodicWorker
  @spec tick(map()) :: map()
  def tick(state) do
    now = state.clock.()

    case state.list.(status: "active") do
      {:ok, experiments} -> Enum.each(experiments, &checkpoint(&1, now, state.checkpoint))
      {:error, reason} -> Logger.warning("experiment checkpoint listing failed: #{inspect(reason)}")
    end

    state
  end

  defp checkpoint(%{id: id}, now, callback) do
    case callback.(id, now) do
      {:ok, _result} -> :ok
      :ok -> :ok
      {:error, reason} -> Logger.warning("experiment #{id} checkpoint failed: #{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("experiment #{id} checkpoint raised: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.warning("experiment #{id} checkpoint caught #{kind}: #{inspect(reason)}")
  end

  defp checkpoint(_unreadable, _now, _callback), do: :ok

  defp interval do
    case Aiur.Config.settings() do
      {:ok, %{experiments: %{checkpoint_interval_ms: interval}}} -> interval
      _unconfigured -> 3_600_000
    end
  end
end
