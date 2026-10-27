defmodule Aiur.AgentList.Renderer.Listener do
  @moduledoc "Read-only listener mode and held-message count for the fleet board."

  alias Aiur.AgentList.Renderer.Text

  @spec label(map() | term()) :: String.t()
  def label(listener) when is_map(listener) do
    effective = mode(listener[:effective])
    requested = mode(listener[:requested])
    mode_label = if requested != effective and requested != "unavailable", do: "#{effective} (req #{requested})", else: effective

    count =
      case listener[:unread_count] do
        n when is_integer(n) and n >= 0 -> Integer.to_string(n)
        _ -> "?"
      end

    "#{mode_label} / #{count} unread"
  end

  def label(_), do: "unavailable / ? unread"

  @spec width([map()]) :: non_neg_integer()
  def width(summaries) do
    if Enum.any?(summaries, &Map.has_key?(&1, :listener)) do
      summaries |> Enum.map(&String.length(label(&1[:listener]))) |> Enum.max(fn -> 0 end)
    else
      0
    end
  end

  @spec block(map(), map()) :: iodata()
  def block(summary, %{listener_width: width}) when width > 0, do: [" ", Text.cell(label(summary[:listener]), width)]
  def block(_summary, _layout), do: []

  defp mode(mode) when mode in [:steer, :sync, :async], do: Atom.to_string(mode)
  defp mode(_), do: "unavailable"
end
