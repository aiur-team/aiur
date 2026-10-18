defmodule Aiur.RunTelemetry.SummaryIndex do
  @moduledoc "Reads bounded metadata from materialized run summaries."

  alias Aiur.RunTelemetry.Summaries

  @tail_bytes 256 * 1024

  @spec time_range_end(String.t()) ::
          {:ok, String.t(), non_neg_integer(), non_neg_integer()} | {:error, term(), non_neg_integer(), non_neg_integer()}
  def time_range_end(boot_id) when is_binary(boot_id) do
    case File.open(Summaries.run_summary_path(boot_id), [:read, :binary]) do
      {:ok, device} -> read_time_range_end(device)
      {:error, reason} -> {:error, reason, 0, 0}
    end
  end

  defp read_time_range_end(device) do
    result = read_tail(device)
    File.close(device)
    result
  end

  defp read_tail(device) do
    with {:ok, size} <- :file.position(device, :eof),
         bytes <- min(size, @tail_bytes),
         {:ok, _position} <- :file.position(device, size - bytes),
         {:ok, tail} <- :file.read(device, bytes) do
      case extract_time_range_end(tail) do
        {:ok, observed_at} ->
          {:ok, observed_at, bytes, size}

        {:error, _reason} ->
          read_head(device, size, bytes)
      end
    else
      {:error, reason} -> {:error, reason, 0, 0}
    end
  end

  defp read_head(device, size, tail_bytes) do
    bytes = min(size, @tail_bytes)

    with {:ok, _position} <- :file.position(device, :bof),
         {:ok, head} <- :file.read(device, bytes),
         {:ok, observed_at} <- extract_time_range_end(head) do
      {:ok, observed_at, tail_bytes + bytes, size}
    else
      {:error, reason} -> {:error, reason, tail_bytes, size}
    end
  end

  defp extract_time_range_end(tail) do
    case Regex.scan(~r/"time_range"\s*:\s*\{[^}]*"end"\s*:\s*"([^"]+)"/s, tail) do
      [] -> {:error, :missing_time_range}
      matches -> {:ok, matches |> List.last() |> Enum.at(1)}
    end
  end
end
