defmodule Aiur.BuildOrder.History.TelemetryScan do
  @moduledoc "Boot-only streaming recovery of dispatch timestamps."
  alias Aiur.BuildOrder.History.Feed

  @spec dispatches(Path.t()) :: map()
  def dispatches(path) do
    path |> File.stream!() |> Enum.reduce(%{}, &dispatch/2)
  rescue
    error in File.Error -> if error.reason == :enoent, do: %{}, else: reraise(error, __STACKTRACE__)
  end

  defp earliest(old, at), do: if(DateTime.compare(at, old) == :lt, do: at, else: old)

  defp dispatch(line, acc) do
    if String.contains?(line, "dispatch") do
      with {:ok, %{"timestamp" => timestamp, "attributes" => %{"event" => "dispatch", "boundary" => "point", "ticket" => ticket}}} <- Jason.decode(line),
           n when not is_nil(n) <- Feed.number(ticket),
           %DateTime{} = at <- Feed.date(timestamp) do
        Map.update(acc, n, at, &earliest(&1, at))
      else
        _other -> acc
      end
    else
      acc
    end
  end
end
