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

  # The web renderer interpolates these tokens into a stylesheet, so a token
  # carrying markup would break out of the <style> element it is written into.
  for {bucket, state} <- @contract["states"] do
    unless is_integer(state["rank"]) and
             Enum.all?(
               ["glow", "face", "accent", "label"],
               &(is_binary(state[&1]) and state[&1] != "" and not String.contains?(state[&1], ["<", ">"]))
             ) do
      raise "Stream Deck state #{inspect(bucket)} has malformed visual tokens"
    end
  end

  progress = @contract["progress"]

  unless Enum.all?(["minimum", "maximum"], &is_number(progress[&1])) and
           progress["maximum"] > progress["minimum"] and
           Enum.all?(["fill", "complete_fill"], &(is_binary(progress[&1]) and progress[&1] != "" and not String.contains?(progress[&1], ["<", ">"]))) do
    raise "Stream Deck progress contract is malformed"
  end

  unless Enum.all?(@expected_badges, &(is_binary(@contract["direction_badges"][&1]["color"]) and @contract["direction_badges"][&1]["color"] != "")) do
    raise "Stream Deck direction badge contract is malformed"
  end

  unless is_boolean(@contract["footers"]["queued"]["ready_when"]) do
    raise "Stream Deck queued footer readiness contract is malformed"
  end

  @spec states() :: %{String.t() => map()}
  def states, do: @contract["states"]

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

  @spec footer(atom() | String.t(), term()) :: %{kind: String.t(), label: String.t(), dependency: String.t() | nil, ready?: boolean()}
  def footer(bucket, dependency_ready) do
    state = state!(bucket)

    if bucket == :queued or bucket == "queued" do
      queued = @contract["footers"]["queued"]
      # Fail-closed: only the exact `ready_when` value reads as ready, so an
      # absent or unrecognised flag renders blocked on both renderers.
      ready? = dependency_ready == queued["ready_when"]
      %{kind: queued["kind"], label: state["label"], dependency: if(ready?, do: queued["ready_label"], else: queued["blocked_label"]), ready?: ready?}
    else
      %{kind: @contract["footers"]["progress"]["kind"], label: state["label"], dependency: nil, ready?: false}
    end
  end

  @spec footer_for_agent(atom() | String.t(), map()) :: %{kind: String.t(), label: String.t(), dependency: String.t() | nil, ready?: boolean()}
  def footer_for_agent(bucket, agent) when is_map(agent), do: footer(bucket, Map.get(agent, :dependency_ready))

  @spec progress_color(number()) :: String.t()
  @doc """
  One fill colour at every measured value, with a brighter shade at 100% so
  completion reads at a glance. A hue ramp is deliberately not used: it makes
  the bar read as two segments of data (and, on the device, as two tones of
  grey at low saturation). Completion is a shade change, not a different hue.
  """
  def progress_color(percent) when is_number(percent) do
    progress = @contract["progress"]
    minimum = progress["minimum"]
    maximum = progress["maximum"]
    clamped = min(max(percent, minimum), maximum)
    if clamped >= maximum, do: progress["complete_fill"], else: progress["fill"]
  end

  @spec direction_badges() :: %{String.t() => map()}
  def direction_badges, do: @contract["direction_badges"]

  @spec direction_badge!(atom() | String.t()) :: map()
  def direction_badge!(badge) when is_atom(badge), do: direction_badge!(Atom.to_string(badge))

  def direction_badge!(badge) when is_binary(badge) do
    case Map.fetch(@contract["direction_badges"], badge) do
      {:ok, direction_badge} -> direction_badge
      :error -> raise ArgumentError, "unhandled Stream Deck direction badge: #{inspect(badge)}"
    end
  end
end
