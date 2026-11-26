defmodule Aiur.Experiments.WindowEvents.Limits do
  @moduledoc false
  alias Aiur.Experiments.WindowEvents
  @max_events 5_000
  @max_bytes 4 * 1_024 * 1_024
  @max_snapshots 32
  @header_bytes 4_096

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @spec snapshots_available?(non_neg_integer()) :: boolean()
  def snapshots_available?(count), do: count < @max_snapshots

  @spec events([map()]) :: {[map()], [String.t()]}
  def events(events) do
    {rows, _count, _bytes, missing} = Enum.reduce(events, {[], 0, 0, []}, &keep_event/2)
    {Enum.reverse(rows), Enum.uniq(missing)}
  end

  defp keep_event(event, {rows, count, bytes, missing}) do
    size = WindowEvents.encoded_size(event) + 1

    if count < @max_events and bytes + size <= @max_bytes - @header_bytes do
      {[event | rows], count + 1, bytes + size, missing}
    else
      source = if event["source"] == "local", do: "telemetry", else: event["source"] || "unknown"
      {rows, count, bytes, [source | missing]}
    end
  end
end
