defmodule AiurWeb.StreamdeckKeyFaceContractTest do
  use ExUnit.Case, async: true

  alias AiurWeb.StreamdeckKeyFaceContract

  @states [
    {"alert", 0, "#ffcf87", "linear-gradient(180deg,#241d0e,#15110a)", "linear-gradient(180deg,#ffc061,#e08a1e)", "Needs input"},
    {"stuck", 1, "#ff9a90", "linear-gradient(180deg,#271317,#160c0e)", "linear-gradient(180deg,#ff6a5e,#c0392b)", "Stuck"},
    {"running", 2, "#9fd0ff", "linear-gradient(180deg,#18212d,#0f151d)", "linear-gradient(180deg,#3f8bff,#7b4bf5)", "Running"},
    {"paused", 3, "#c2c6cf", "linear-gradient(180deg,#1e2025,#131419)", "linear-gradient(180deg,#4a4d55,#33363d)", "Paused"},
    {"queued", 4, "#9096a4", "linear-gradient(180deg,#191b21,#111318)", "linear-gradient(180deg,#3a3f47,#23262c)", "Unstarted"}
  ]

  test "web state tokens and ordering are derived from the shared contract" do
    for {bucket, rank, accent, face, glow, label} <- @states do
      assert StreamdeckKeyFaceContract.bucket_rank!(bucket) == rank

      assert StreamdeckKeyFaceContract.state!(bucket) ==
               %{
                 "rank" => rank,
                 "accent" => accent,
                 "face" => face,
                 "glow" => glow,
                 "label" => label
               }
               |> maybe_pulse(bucket)
    end
  end

  test "progress hue and footer variants are contract-derived" do
    assert StreamdeckKeyFaceContract.progress_color(0) == "hsl(0 72% 50%)"
    assert StreamdeckKeyFaceContract.progress_color(50) == "hsl(63 72% 50%)"
    assert StreamdeckKeyFaceContract.progress_color(100) == "hsl(125 72% 50%)"
    assert StreamdeckKeyFaceContract.footer(:running, false) == %{kind: "progress", label: "Running", dependency: nil}
    assert StreamdeckKeyFaceContract.footer(:queued, true) == %{kind: "queued", label: "Unstarted", dependency: "Unblocked"}
    assert StreamdeckKeyFaceContract.footer(:queued, false) == %{kind: "queued", label: "Unstarted", dependency: "Blocked"}
    assert StreamdeckKeyFaceContract.footer(:queued, nil) == %{kind: "queued", label: "Unstarted", dependency: "Blocked"}
    assert StreamdeckKeyFaceContract.footer_for_agent(:queued, %{}) == %{kind: "queued", label: "Unstarted", dependency: "Blocked"}
  end

  test "direction badges are exhaustive and unknown values fail closed" do
    assert StreamdeckKeyFaceContract.direction_badge!(:EMIT) == %{"color" => "#9fd0ff"}
    assert StreamdeckKeyFaceContract.direction_badge!("CONSUME") == %{"color" => "#88e0a6"}
    assert_raise ArgumentError, ~r/unhandled Stream Deck key state/, fn -> StreamdeckKeyFaceContract.state!(:unknown) end
    assert_raise ArgumentError, ~r/unhandled Stream Deck direction badge/, fn -> StreamdeckKeyFaceContract.direction_badge!("UNKNOWN") end
  end

  defp maybe_pulse(state, "alert"), do: Map.put(state, "pulse_seconds", 1.6)
  defp maybe_pulse(state, "stuck"), do: Map.put(state, "pulse_seconds", 1.4)
  defp maybe_pulse(state, _bucket), do: state
end
