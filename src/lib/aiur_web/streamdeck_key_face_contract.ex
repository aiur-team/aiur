defmodule AiurWeb.StreamdeckKeyFaceContract do
  @moduledoc """
  Data-only visual contract shared by the web emulator and `@aiur/streamdeck`.

  Renderers read the same JSON but retain their own HTML/CSS or bitmap drawing
  routines. The compile-time validation deliberately has no fallback: a state
  or direction badge added to the data must be handled by both renderers.
  """

  @contract_path Path.expand("../../../packages/streamdeck/src/key-face-contract.json", __DIR__)
  @external_resource @contract_path
  @contract @contract_path |> File.read!() |> Jason.decode!()
  @expected_states ~w(alert stuck running paused queued)
  @expected_badges ~w(EMIT CONSUME AGENT SYSTEM INFO)

  for {map, expected, label} <- [
        {@contract["states"], @expected_states, "states"},
        {@contract["direction_badges"], @expected_badges, "direction badges"}
      ] do
    actual = map |> Map.keys() |> Enum.sort()

    unless actual == Enum.sort(expected) do
      raise "Stream Deck #{label} must be exhaustive; expected #{inspect(Enum.sort(expected))}, got #{inspect(actual)}"
    end
  end

  for {bucket, state} <- @contract["states"] do
    unless is_integer(state["rank"]) and Enum.all?(["glow", "face", "accent", "label"], &(is_binary(state[&1]) and state[&1] != "")) do
      raise "Stream Deck state #{inspect(bucket)} has malformed visual tokens"
    end
  end

  progress = @contract["progress"]

  unless Enum.all?(["minimum", "maximum", "hue_start", "hue_end", "saturation", "lightness", "round_decimals"], &is_number(progress[&1])) and
           progress["maximum"] > progress["minimum"] and is_integer(progress["round_decimals"]) and progress["round_decimals"] >= 0 do
    raise "Stream Deck progress contract is malformed"
  end

  unless Enum.all?(@expected_badges, &(is_binary(@contract["direction_badges"][&1]["color"]) and @contract["direction_badges"][&1]["color"] != "")) do
    raise "Stream Deck direction badge contract is malformed"
  end

  unless is_boolean(@contract["footers"]["queued"]["ready_when"]) do
    raise "Stream Deck queued footer readiness contract is malformed"
  end

  @spec state!(atom() | String.t()) :: map()
  def state!(bucket) when is_atom(bucket), do: state!(Atom.to_string(bucket))

  def state!(bucket) when is_binary(bucket) do
    case Map.fetch(@contract["states"], bucket) do
      {:ok, state} -> state
      :error -> raise ArgumentError, "unhandled Stream Deck key state: #{inspect(bucket)}"
    end
  end

  @spec known_state?(atom() | String.t()) :: boolean()
  def known_state?(bucket) do
    state!(bucket)
    true
  rescue
    ArgumentError -> false
  end

  @spec bucket_rank!(atom() | String.t()) :: non_neg_integer()
  def bucket_rank!(bucket), do: state!(bucket)["rank"]

  @spec footer(atom() | String.t(), term()) :: %{kind: String.t(), label: String.t(), dependency: String.t() | nil}
  def footer(bucket, dependency_ready) do
    state = state!(bucket)

    if bucket == :queued or bucket == "queued" do
      queued = @contract["footers"]["queued"]
      %{kind: queued["kind"], label: state["label"], dependency: if(dependency_ready == queued["ready_when"], do: queued["ready_label"], else: queued["blocked_label"])}
    else
      %{kind: @contract["footers"]["progress"]["kind"], label: state["label"], dependency: nil}
    end
  end

  @spec progress_color(number()) :: String.t()
  def progress_color(percent) when is_number(percent) do
    progress = @contract["progress"]
    minimum = progress["minimum"]
    maximum = progress["maximum"]
    clamped = min(max(percent, minimum), maximum)
    hue = progress["hue_start"] + (clamped - minimum) / (maximum - minimum) * (progress["hue_end"] - progress["hue_start"])
    hue = Float.round(hue, progress["round_decimals"])
    "hsl(#{format_number(hue)} #{progress["saturation"]}% #{progress["lightness"]}%)"
  end

  @spec direction_badge!(atom() | String.t()) :: map()
  def direction_badge!(badge) when is_atom(badge), do: direction_badge!(Atom.to_string(badge))

  def direction_badge!(badge) when is_binary(badge) do
    case Map.fetch(@contract["direction_badges"], badge) do
      {:ok, direction_badge} -> direction_badge
      :error -> raise ArgumentError, "unhandled Stream Deck direction badge: #{inspect(badge)}"
    end
  end

  defp format_number(number) when trunc(number) == number, do: Integer.to_string(trunc(number))
  defp format_number(number), do: :erlang.float_to_binary(number, decimals: 3) |> String.trim_trailing("0") |> String.trim_trailing(".")
end
