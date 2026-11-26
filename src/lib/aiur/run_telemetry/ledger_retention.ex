defmodule Aiur.RunTelemetry.LedgerRetention do
  @moduledoc """
  Checkpoints the canonical stream before retention deletes lifecycle evidence.
  The writer waits synchronously for materialization (five-second timeout; raw evidence survives a timeout);
  the 2026-10-12 retained-data census measured a 3.8-second checkpoint.
  """
  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.{Retention, Summaries}

  @spec prune(Path.t(), keyword()) :: :ok | {:error, term()}
  def prune(path, opts) do
    # Only the daemon's canonical stream contributes to its ledger.
    if Path.expand(path) == Path.expand(RunTelemetry.telemetry_file()) and RunTelemetry.telemetry_enabled?() do
      materialize_opts = Keyword.merge([telemetry_file: path], Keyword.get(opts, :materialize_opts, []))

      case Summaries.materialize(Keyword.put(materialize_opts, :timeout_ms, 5_000)) do
        {:ok, _output} -> Retention.prune(path, Keyword.delete(opts, :materialize_opts))
        {:error, reason} -> {:error, {:ledger_checkpoint_failed, reason}}
      end
    else
      Retention.prune(path, opts)
    end
  end
end
