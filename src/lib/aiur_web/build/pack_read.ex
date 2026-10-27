defmodule AiurWeb.Build.PackRead do
  @moduledoc false
  alias AiurWeb.Build.UnfiledRows

  @spec read(map(), keyword()) :: map()
  def read(index, opts) do
    now = Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end).()
    rows = Map.values(index.all)
    planned = Enum.filter(rows, &(&1.sec == "plan"))

    context = %{
      filed_numbers: MapSet.new(rows, & &1.num),
      done_numbers: MapSet.new(Enum.filter(rows, &(&1.status == "done")), & &1.num),
      max_wave: Enum.max(Enum.map(planned, &(&1.wave || 0)), fn -> 0 end),
      max_ord: Enum.max(Enum.map(planned, & &1.ord), fn -> -1 end),
      epics: MapSet.new(Map.keys(index.epics)),
      now: now
    }

    UnfiledRows.build(context, Keyword.get(opts, :packs_opts, []))
  end
end
