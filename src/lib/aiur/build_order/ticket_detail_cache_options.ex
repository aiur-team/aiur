defmodule Aiur.BuildOrder.TicketDetailCache.Options do
  @moduledoc false

  alias Aiur.BuildOrder.TicketDetail

  @default_freshness_ms 30_000
  @default_refresh_timeout_ms 30_000
  @default_max_entries 32
  @max_freshness_ms 300_000
  @max_refresh_timeout_ms 30_000
  @max_entries 100

  @spec new(keyword()) :: map()
  def new(opts) do
    opts = runtime_options(opts)

    %{
      entries: %{},
      inflight_by_ref: %{},
      next_generation: 1,
      configured_repo: Keyword.get(opts, :configured_repo),
      active_repository: :unknown,
      freshness_ms: bounded_positive_option(opts, :freshness_ms, @default_freshness_ms, @max_freshness_ms),
      refresh_timeout_ms:
        bounded_positive_option(
          opts,
          :refresh_timeout_ms,
          @default_refresh_timeout_ms,
          @max_refresh_timeout_ms
        ),
      max_entries: bounded_positive_option(opts, :max_entries, @default_max_entries, @max_entries),
      max_description_bytes:
        bounded_positive_option(
          opts,
          :max_description_bytes,
          TicketDetail.default_max_description_bytes(),
          TicketDetail.default_max_description_bytes()
        ),
      reader: Keyword.get(opts, :reader),
      task_supervisor: Keyword.get(opts, :task_supervisor, Aiur.TaskSupervisor),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      clock_ms: Keyword.get(opts, :clock_ms, fn -> System.monotonic_time(:millisecond) end),
      configuration_subscriber: Keyword.get(opts, :configuration_subscriber, &Aiur.WorkflowStore.subscribe/1),
      reset_epoch: reset_epoch(opts)
    }
  end

  defp bounded_positive_option(opts, key, default, maximum) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 and value <= maximum -> value
      _ -> default
    end
  end

  defp runtime_options(opts) do
    case Keyword.pop(opts, :runtime_config?, false) do
      {true, opts} -> Keyword.merge(Aiur.Config.build_order_ticket_detail_cache_options(), opts)
      {_runtime_config?, opts} -> opts
    end
  end

  defp reset_epoch(opts) do
    case Keyword.get(opts, :reset_epoch, fn -> System.unique_integer([:positive, :monotonic]) end) do
      epoch when is_integer(epoch) and epoch > 0 -> epoch
      epoch_fun when is_function(epoch_fun, 0) -> valid_epoch_or_default(epoch_fun.())
      _ -> System.unique_integer([:positive, :monotonic])
    end
  rescue
    _error -> System.unique_integer([:positive, :monotonic])
  end

  defp valid_epoch_or_default(epoch) when is_integer(epoch) and epoch > 0, do: epoch
  defp valid_epoch_or_default(_epoch), do: System.unique_integer([:positive, :monotonic])
end
