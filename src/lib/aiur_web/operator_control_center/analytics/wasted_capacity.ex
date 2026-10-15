defmodule AiurWeb.OperatorControlCenter.Analytics.WastedCapacity do
  @moduledoc false

  @spec summarize([map()], number(), boolean()) :: {number() | nil, boolean()}
  def summarize(series, bucket_hours, cap_available?) do
    {hours, known} =
      Enum.reduce(series, {0.0, 0}, fn bucket, {total, count} ->
        case {Map.get(bucket, :fleet_agents_effective), Map.get(bucket, :conc)} do
          {cap, occupied} when is_number(cap) and is_number(occupied) ->
            {total + max(cap - occupied, 0) * bucket_hours, count + 1}

          _missing ->
            {total, count}
        end
      end)

    {if(known == 0, do: nil, else: Float.round(hours, 1)), known < length(series) or not cap_available?}
  end
end
