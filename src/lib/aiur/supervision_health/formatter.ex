defmodule Aiur.SupervisionHealth.Formatter do
  @moduledoc false

  @spec format(map()) :: String.t()
  def format(%{expected: expected, healthy: healthy, missing: []}), do: "SUPERVISION #{healthy}/#{expected} healthy"

  def format(%{expected: expected, healthy: healthy, missing: missing}) do
    details = Enum.map_join(missing, ", ", &format_missing/1)
    "SUPERVISION #{healthy}/#{expected} — #{details}"
  end

  @spec format_missing(map()) :: String.t()
  def format_missing(%{id: id, path: path, reason: nil}), do: "#{display_path(path, id)} DOWN"

  def format_missing(%{id: id, path: path, reason: reason}),
    do: "#{display_path(path, id)} DOWN (last termination: #{inspect(reason)})"

  def format_missing(%{id: id, reason: nil}), do: "#{display_id(id)} DOWN"
  def format_missing(%{id: id, reason: reason}), do: "#{display_id(id)} DOWN (last termination: #{inspect(reason)})"

  defp display_path([_ | _] = path, _id), do: Enum.map_join(path, "/", &display_id/1)
  defp display_path(_, id), do: display_id(id)

  defp display_id(id) when is_atom(id), do: id |> Module.split() |> Enum.join(".")
  defp display_id(id), do: inspect(id)
end
