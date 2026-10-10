defmodule AiurWeb.Build.UsageAPIs do
  @moduledoc false
  alias AiurWeb.Build.Usage

  @spec rows(term(), map(), integer()) :: [map()]
  def rows(github, elevenlabs, now), do: [github_row(github, now) | elevenlabs_rows(elevenlabs, now)]

  defp github_row(input, now) do
    snapshot =
      case input do
        {:ok, snapshot} -> snapshot
        _ -> %{state: :unavailable, windows: %{}, backoffs: []}
      end

    lines = Enum.map(~w(core graphql), &github_line(snapshot, &1, now))
    observations = snapshot.windows |> Map.values() |> Enum.map(&Usage.ms(Map.get(&1, :observed_at))) |> Enum.reject(&is_nil/1)
    %{Usage.row("GitHub") | icon: "github", lines: lines, observed_at: Enum.max(observations, fn -> nil end), stale: Enum.any?(lines, &ended?(&1.reset_at, now))}
  end

  defp github_line(snapshot, resource, now) do
    label = if resource == "core", do: "Requests left", else: "Points left"
    window = if snapshot.state != :unknown, do: Map.get(snapshot.windows, resource)
    base = %{tag: if(resource == "core", do: "core", else: "gql"), acc: [nil], reset_at: nil, win: "1h", tip: [[label, "not observed yet"]], hold_until: nil}

    case window do
      %{used_percent: percent, limit: limit, remaining: remaining} when is_number(percent) and is_number(limit) and limit > 0 and is_number(remaining) ->
        reset = Usage.ms(window.reset_at)
        %{base | acc: [Usage.percent(percent)], reset_at: reset, tip: [[label, "#{commas(remaining)} of #{commas(limit)}"]], hold_until: hold_until(snapshot, resource, window, now)}

      _ ->
        note = if snapshot.state == :unavailable, do: "GitHub budget meter unavailable", else: "not observed yet"
        %{base | tip: [[label, note]]}
    end
  end

  defp hold_until(snapshot, resource, window, now) do
    reset = Usage.ms(window.reset_at)
    floor = if window.remaining * 100 <= window.limit * 10 and future?(reset, now), do: reset
    backoff = snapshot |> Map.get(:backoffs, []) |> Enum.filter(&(&1.resource == resource)) |> Enum.map(&Usage.ms(&1.until)) |> Enum.filter(&future?(&1, now)) |> Enum.max(fn -> nil end)
    later(floor, backoff)
  end

  defp elevenlabs_rows(%{state: :unconfigured}, _now), do: []

  defp elevenlabs_rows(snapshot, now) do
    {percent, reset, text} =
      case snapshot do
        %{state: :observed, window: window} -> {Usage.percent(window.used_percent), Usage.ms(window.reset_at), Usage.compact_number(window.remaining)}
        %{state: :failed, failure: failure} -> {nil, nil, Usage.elevenlabs_failure(failure)}
        _ -> {nil, nil, "not observed yet"}
      end

    line = %{tag: "credits", acc: [percent], reset_at: reset, win: nil, tip: [["Credits left", text]], hold_until: nil}
    [%{Usage.row("ElevenLabs") | mono: "E", lines: [line], observed_at: Usage.ms(Map.get(snapshot, :observed_at)), stale: ended?(reset, now)}]
  end

  defp commas(number), do: number |> round() |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  defp future?(at, now), do: is_integer(at) and at > now
  defp ended?(at, now), do: is_integer(at) and at < now
  defp later(nil, at), do: at
  defp later(at, nil), do: at
  defp later(a, b), do: max(a, b)
end
