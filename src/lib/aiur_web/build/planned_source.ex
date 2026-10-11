defmodule AiurWeb.Build.PlannedSource do
  @moduledoc "Queue health without substituting snapshot capture times for observation ages."
  @spec build(map() | {:error, term()}) :: map()
  def build({:error, :not_installed}), do: source("disabled", nil, "not_installed")
  def build({:error, _reason}), do: source("unavailable", nil, "read_failed")
  def build(%{status: :store_unavailable}), do: source("unavailable", nil, "store_unavailable")
  def build(%{status: status}) when status in [:disabled, :unsupported_tracker], do: source("disabled", nil, to_string(status))

  def build(%{status: status, sources: sources}) when status in [:running, :writes_paused] do
    observations = sources |> Enum.sort_by(fn {key, _value} -> key end) |> Enum.map(&elem(&1, 1))
    result = observations(observations)
    if status == :writes_paused, do: %{result | reason: "writes_paused"}, else: result
  end

  defp observations(sources) do
    if sources == [] or Enum.any?(sources, &(&1.freshness == :unknown)) do
      source("stale", nil, "observation_unknown")
    else
      oldest = sources |> Enum.map(&milliseconds(&1.observed_at)) |> Enum.min()
      stale = Enum.filter(sources, &(&1.freshness == :stale))
      if stale == [], do: source("ok", oldest, nil), else: source("stale", oldest, reason(stale))
    end
  end

  defp reason(stale), do: stale |> Enum.flat_map(&Map.get(&1, :reasons, [])) |> List.first() |> reason_text()
  defp reason_text(nil), do: "stale"
  defp reason_text(reason) when is_atom(reason) or is_binary(reason), do: to_string(reason)
  defp reason_text(reason), do: inspect(reason)
  defp milliseconds(%DateTime{} = time), do: DateTime.to_unix(time, :millisecond)
  defp milliseconds(time) when is_integer(time), do: time
  defp milliseconds(_time), do: nil
  defp source(state, observed, reason), do: %{state: state, observed_at: observed, reason: reason}
end
