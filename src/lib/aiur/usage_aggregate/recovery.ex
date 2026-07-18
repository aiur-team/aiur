defmodule Aiur.UsageAggregate.Recovery do
  @moduledoc false

  # File-only boot for the aggregate projection. It validates the latest
  # checkpoint and returns the base projection plus whether a full rebuild from
  # the retained DASH-009 raw authority is required. It never touches the ledger
  # itself; the store performs the position-gated catch-up/rebuild after it has
  # subscribed, so no accepted delta can slip through a scan-to-subscribe gap.

  alias Aiur.{Config, Fs}
  alias Aiur.UsageAggregate.{Checkpoint, Paths, Projection}

  @default_max_checkpoint_bytes 33_554_432

  @spec options(keyword()) :: map()
  def options(opts) do
    %{
      sync_fun: Keyword.get(opts, :filesystem_sync_fun, &Fs.sync_filesystem/0),
      quarantine_fun: Keyword.get(opts, :quarantine_fun, &Paths.quarantine/3),
      degraded_marker_fun: Keyword.get(opts, :degraded_marker_fun, &Paths.write_degraded_marker/3),
      checkpoint_load_fun: Keyword.get(opts, :checkpoint_load_fun, &Checkpoint.load/2),
      max_checkpoint_bytes: Keyword.get(opts, :max_checkpoint_bytes, @default_max_checkpoint_bytes)
    }
  end

  @spec state_dir(keyword()) :: {:ok, String.t()} | {:error, atom()}
  def state_dir(opts) do
    case Keyword.get(opts, :state_dir) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> Config.Paths.usage_aggregate_state_dir()
    end
  end

  @spec boot(String.t(), map()) :: map()
  def boot(root, persistence) when is_binary(root) and is_map(persistence) do
    case Paths.prepare(root, persistence.sync_fun) do
      {:ok, paths} -> load(paths, persistence)
      {:error, reason} -> unavailable(safe_reason(reason))
    end
  end

  @spec unavailable(term()) :: map()
  def unavailable(reason) do
    %{
      paths: nil,
      projection: Projection.new(),
      checkpoint_status: :unavailable,
      rebuild?: true,
      health: {:unavailable, safe_reason(reason)},
      writable?: false
    }
  end

  defp load(paths, persistence) do
    case persistence.checkpoint_load_fun.(paths.checkpoint_path, max_bytes: persistence.max_checkpoint_bytes) do
      :missing -> missing(paths)
      {:ok, projection} -> restored(paths, projection)
      {:corrupt, reason} -> corrupt(paths, reason, persistence)
    end
  end

  defp missing(paths) do
    %{
      paths: paths,
      projection: Projection.new(),
      checkpoint_status: :missing,
      rebuild?: true,
      health: :healthy,
      writable?: true
    }
  end

  defp restored(paths, projection) do
    health = if Paths.degraded_marker(paths.degraded_path) == :absent, do: :healthy, else: {:degraded, :recovering}

    %{
      paths: paths,
      projection: projection,
      checkpoint_status: :healthy,
      rebuild?: false,
      health: health,
      writable?: true
    }
  end

  defp corrupt(paths, reason, persistence) do
    _ = persistence.quarantine_fun.(paths.checkpoint_path, paths.quarantine_dir, persistence.sync_fun)
    _ = persistence.degraded_marker_fun.(paths.degraded_path, :checkpoint_corrupt, persistence.sync_fun)

    %{
      paths: paths,
      projection: Projection.new(),
      checkpoint_status: {:corrupt, safe_reason(reason)},
      rebuild?: true,
      health: {:degraded, :checkpoint_corrupt},
      writable?: true
    }
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :state_unavailable
end
