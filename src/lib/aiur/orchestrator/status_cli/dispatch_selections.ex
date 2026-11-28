defmodule Aiur.Orchestrator.StatusCLI.DispatchSelections do
  @moduledoc false

  @spec print(map() | nil) :: :ok
  def print(%{dispatch_selections: selections}) do
    Enum.each(selections, fn %{chosen: chosen, at: at, skipped: skipped} ->
      skipped_text = Enum.map_join(skipped, ", ", &"#{&1.ticket} (#{&1.reason})")
      IO.puts("DISPATCH #{DateTime.to_iso8601(at)} chose #{chosen}" <> if(skipped == [], do: "", else: " | skipped #{skipped_text}"))
    end)
  end

  def print(_capacity), do: :ok
end
