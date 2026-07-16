defmodule Aiur.BuildOrder.TicketHistoryProvider.Options do
  @moduledoc false

  alias Aiur.BuildOrder.{TicketDetail, TicketHistory.Normalizer}
  alias Aiur.{Config, IssueLog, TicketActivity, WorkflowStore}
  alias Aiur.Events.Exchange

  @default_history_limit 50
  @default_max_identities 100
  @default_stale_after_ms 60_000
  @max_stale_after_ms 300_000

  @spec new(keyword()) :: map()
  def new(opts) do
    opts = runtime_options(opts)

    %{
      history_limit: bounded_positive(opts, :history_limit, @default_history_limit, Normalizer.hard_limit()),
      max_identities: bounded_positive(opts, :max_identities, @default_max_identities, Normalizer.hard_limit()),
      stale_after_ms: bounded_positive(opts, :stale_after_ms, @default_stale_after_ms, @max_stale_after_ms),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      history_fun: Keyword.get(opts, :history_fun, &IssueLog.event_history/2),
      activity_snapshot_fun: Keyword.get(opts, :activity_snapshot_fun, &TicketActivity.snapshot/1),
      activity_snapshots_fun: Keyword.get(opts, :activity_snapshots_fun, &TicketActivity.snapshots/0),
      exchange_subscribe_fun: Keyword.get(opts, :exchange_subscribe_fun, fn -> Exchange.subscribe("ticket.*.#") end),
      activity_subscribe_fun: Keyword.get(opts, :activity_subscribe_fun, &TicketActivity.subscribe/0),
      configuration_subscribe_fun: Keyword.get(opts, :configuration_subscribe_fun, &WorkflowStore.subscribe/1),
      repository_snapshot_fun: repository_snapshot_fun(opts),
      reset_epoch: reset_epoch(opts)
    }
  end

  defp runtime_options(opts) do
    case Keyword.pop(opts, :runtime_config?, false) do
      {true, opts} -> Keyword.merge(Config.build_order_ticket_history_options(), opts)
      {_runtime?, opts} -> opts
    end
  end

  defp repository_snapshot_fun(opts) do
    case Keyword.get(opts, :configured_repo) do
      {owner, repository} when is_binary(owner) and is_binary(repository) ->
        generation = Keyword.get(opts, :configuration_generation, 1)
        fn -> {:ok, {owner, repository}, generation} end

      _ ->
        Keyword.get(opts, :repository_snapshot_fun, fn ->
          TicketDetail.configured_repository_snapshot([])
        end)
    end
  end

  defp bounded_positive(opts, key, default, maximum) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 and value <= maximum -> value
      _ -> default
    end
  end

  defp reset_epoch(opts) do
    case Keyword.get(opts, :reset_epoch, fn -> System.unique_integer([:positive, :monotonic]) end) do
      epoch when is_integer(epoch) and epoch > 0 -> epoch
      fun when is_function(fun, 0) -> positive_epoch(fun.())
      _ -> positive_epoch(nil)
    end
  rescue
    _error -> positive_epoch(nil)
  end

  defp positive_epoch(epoch) when is_integer(epoch) and epoch > 0, do: epoch
  defp positive_epoch(_epoch), do: System.unique_integer([:positive, :monotonic])
end
