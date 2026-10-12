defmodule Aiur.RunTelemetry.CaptureGaps do
  @moduledoc "Records disabled capture periods independently of the telemetry writer."

  require Logger

  alias Aiur.RunTelemetry
  alias Aiur.RunTelemetry.Summaries

  @spec record() :: :ok
  def record do
    path = Path.join(Summaries.analytics_dir(), "capture-gaps.ndjson")
    row = %{boot_id: RunTelemetry.boot_id(), started_at: DateTime.to_iso8601(RunTelemetry.boot_started_at()), telemetry_enabled: false}

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [Jason.encode!(row), "\n"], [:append]) do
      :ok
    else
      {:error, reason} -> warn(reason)
    end
  rescue
    error -> warn(Exception.message(error))
  catch
    kind, reason -> warn({kind, reason})
  end

  defp warn(reason) do
    Logger.warning("run_telemetry capture_gap_write_failed reason=#{inspect(reason)}")
    :ok
  end
end
