defmodule AiurWeb.OperatorControlCenter.TimeFormat do
  @moduledoc """
  Render dashboard timestamps in the viewer's timezone.

  The dashboard is server-rendered; the browser reports its IANA timezone
  through the LiveSocket connect params, and components format absolute times
  by shifting into that zone. When no zone is known (initial render, fixtures,
  tests) the caller falls back to `Etc/UTC`, keeping existing assertions stable.
  """

  @spec format(DateTime.t() | nil, String.t()) :: String.t()
  def format(nil, _time_zone), do: "unknown"

  def format(%DateTime{} = datetime, time_zone) when is_binary(time_zone) do
    datetime
    |> DateTime.shift_zone!(time_zone)
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  @spec iso8601(DateTime.t() | nil, String.t()) :: String.t()
  def iso8601(nil, _time_zone), do: ""

  def iso8601(%DateTime{} = datetime, time_zone) when is_binary(time_zone) do
    datetime
    |> DateTime.shift_zone!(time_zone)
    |> DateTime.to_iso8601()
  end
end
