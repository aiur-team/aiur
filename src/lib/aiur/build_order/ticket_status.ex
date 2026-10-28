defmodule Aiur.BuildOrder.TicketStatus do
  @moduledoc "Shared Build modal and deck ticket status labels. Unknown agent state remains nil."

  @taxonomy_path Path.expand("../../../priv/static/build-home/ticket-status.json", __DIR__)
  @external_resource @taxonomy_path
  @taxonomy @taxonomy_path |> File.read!() |> Jason.decode!()
  @unknown {@taxonomy["unknown"]["label"], "idle"}

  @spec encode(map() | nil) :: %{label: String.t(), tone: String.t(), agent_state: String.t() | nil}
  def encode(row) do
    state = if row && row[:sec] == "now", do: get_in(row, [:agent, :state])
    {label, tone} = presentation(row)
    %{label: label, tone: tone, agent_state: state}
  end

  defp presentation(%{sec: "now"} = row) do
    case @taxonomy["agent"][get_in(row, [:agent, :state])] do
      %{"label" => label, "cls" => tone} -> {label, tone}
      _ -> @unknown
    end
  end

  defp presentation(%{sec: "hist"} = row), do: pair(@taxonomy["history"][row[:status]])

  defp presentation(%{sec: "plan"} = row) do
    if unfiled?(row) do
      pair(@taxonomy["sections"]["unfiled"])
    else
      {label, tone} = pair(@taxonomy["sections"]["plan"])
      {label <> queue(row[:qpos]), tone}
    end
  end

  defp presentation(%{sec: "nq"}), do: pair(@taxonomy["sections"]["nq"])
  defp presentation(_row), do: @unknown
  defp pair(%{"label" => label, "tone" => tone}), do: {label, tone}
  defp pair(_unknown), do: @unknown

  defp unfiled?(%{num: nil, src: %{kind: "pack"}}), do: true
  defp unfiled?(%{num: nil, id: "pack:" <> _rest} = row), do: is_nil(row[:src])
  defp unfiled?(_row), do: false
  defp queue(nil), do: "Q?"
  defp queue(position) when is_number(position), do: "Q" <> to_string(position)
  defp queue(_position), do: "Q—"
end
