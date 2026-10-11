defmodule Aiur.TestSupport.UsageLedgerRecovery do
  @moduledoc false

  import ExUnit.Assertions

  def instrument_recovery(persistence, recipient) do
    marker_fun = persistence.degraded_marker_fun
    quarantine_fun = persistence.quarantine_fun
    rewrite_fun = persistence.rewrite_segment_fun
    checkpoint_fun = persistence.checkpoint_write_fun

    %{
      persistence
      | degraded_marker_fun: fn path, reason, sync_fun ->
          send(recipient, {:recovery_stage, :marker})
          marker_fun.(path, reason, sync_fun)
        end,
        quarantine_fun: fn path, quarantine_dir, sync_fun ->
          send(recipient, {:recovery_stage, {:quarantine, Path.basename(path)}})
          quarantine_fun.(path, quarantine_dir, sync_fun)
        end,
        rewrite_segment_fun: fn path, records, sync_fun ->
          send(recipient, {:recovery_stage, :segment_rewrite})
          rewrite_fun.(path, records, sync_fun)
        end,
        checkpoint_write_fun: fn path, checkpoint, max_bytes ->
          send(recipient, {:recovery_stage, :checkpoint_rewrite})
          checkpoint_fun.(path, checkpoint, max_bytes)
        end
    }
  end

  def recovery_stages(count) do
    Enum.map(1..count, fn _index ->
      assert_receive {:recovery_stage, stage}, 2_000
      stage
    end)
  end

  def faulted_recovery(persistence, :marker) do
    %{persistence | degraded_marker_fun: fn _path, _reason, _sync_fun -> {:error, :injected_marker_failure} end}
  end

  def faulted_recovery(persistence, :quarantine) do
    %{persistence | quarantine_fun: fn _path, _quarantine_dir, _sync_fun -> {:error, :injected_quarantine_failure} end}
  end

  def faulted_recovery(persistence, :rewrite) do
    %{persistence | rewrite_segment_fun: fn _path, _records, _sync_fun -> {:error, :injected_rewrite_failure} end}
  end

  def faulted_recovery(persistence, :checkpoint_rewrite) do
    %{
      persistence
      | checkpoint_write_fun: fn _path, _checkpoint, _max_bytes ->
          {:error, :injected_checkpoint_failure}
        end
    }
  end

  def fault_after_recovery(persistence, :marker) do
    marker_fun = persistence.degraded_marker_fun

    %{
      persistence
      | degraded_marker_fun: fn path, reason, sync_fun ->
          :ok = marker_fun.(path, reason, sync_fun)
          {:error, :injected_marker_failure}
        end
    }
  end

  def fault_after_recovery(persistence, :quarantine) do
    quarantine_fun = persistence.quarantine_fun

    %{
      persistence
      | quarantine_fun: fn path, quarantine_dir, sync_fun ->
          :ok = quarantine_fun.(path, quarantine_dir, sync_fun)
          {:error, :injected_quarantine_failure}
        end
    }
  end

  def fault_after_recovery(persistence, :rewrite) do
    rewrite_fun = persistence.rewrite_segment_fun

    %{
      persistence
      | rewrite_segment_fun: fn path, records, sync_fun ->
          :ok = rewrite_fun.(path, records, sync_fun)
          {:error, :injected_rewrite_failure}
        end
    }
  end

  def fault_after_recovery(persistence, :checkpoint_rewrite) do
    checkpoint_fun = persistence.checkpoint_write_fun

    %{
      persistence
      | checkpoint_write_fun: fn path, checkpoint, max_bytes ->
          :ok = checkpoint_fun.(path, checkpoint, max_bytes)
          {:error, :injected_checkpoint_failure}
        end
    }
  end

  def fault_after_checkpoint_quarantine(persistence) do
    quarantine_fun = persistence.quarantine_fun

    %{
      persistence
      | quarantine_fun: fn path, quarantine_dir, sync_fun ->
          with :ok <- quarantine_fun.(path, quarantine_dir, sync_fun) do
            if Path.basename(path) == "checkpoint.json",
              do: {:error, :injected_checkpoint_quarantine_failure},
              else: :ok
          end
        end
    }
  end

  def fault_health(:marker), do: {:unavailable, :degraded_marker_failed}
  def fault_health(:quarantine), do: {:unavailable, :quarantine_failed}
  def fault_health(:rewrite), do: {:unavailable, :repair_failed}
  def fault_health(:checkpoint_rewrite), do: {:unavailable, :repair_failed}
end
