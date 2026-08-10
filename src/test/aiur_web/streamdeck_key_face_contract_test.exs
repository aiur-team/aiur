defmodule AiurWeb.StreamdeckKeyFaceContractTest do
  use ExUnit.Case, async: true

  alias AiurWeb.StreamdeckKeyFaceContract

  # The same golden table `packages/streamdeck/test/key-face-contract.test.ts`
  # asserts against. These are literal expected renderings, not a restatement of
  # the formula: a hue rounded differently in one language, or a contract value
  # changed on one side only, fails here rather than drifting silently.
  @vectors_path Path.expand("../../../packages/streamdeck/src/key-face-parity-vectors.json", __DIR__)
  @external_resource @vectors_path
  @vectors @vectors_path |> File.read!() |> Jason.decode!()

  test "the parity table covers every contract state and direction badge" do
    buckets = @vectors["states"] |> Enum.map(& &1["bucket"]) |> Enum.sort()
    badges = @vectors["direction_badges"] |> Enum.map(& &1["badge"]) |> Enum.sort()

    assert buckets == ~w(alert paused queued running stuck)
    assert badges == ~w(AGENT CONSUME EMIT INFO SYSTEM)

    for bucket <- buckets, do: assert(StreamdeckKeyFaceContract.known_state?(bucket))
  end

  test "web state tokens and ordering match the shared parity table" do
    for vector <- @vectors["states"] do
      state = StreamdeckKeyFaceContract.state!(vector["bucket"])

      assert StreamdeckKeyFaceContract.bucket_rank!(vector["bucket"]) == vector["rank"]
      assert state["rank"] == vector["rank"]
      assert state["accent"] == vector["accent"]
      assert state["glow"] == vector["glow"]
      assert state["face"] == vector["face"]
      assert state["label"] == vector["label"]
      assert state["pulse_seconds"] == vector["pulse_seconds"]
    end
  end

  test "progress hue mapping matches the shared parity table" do
    for %{"percent" => percent, "color" => color} <- @vectors["progress"] do
      assert StreamdeckKeyFaceContract.progress_color(percent) == color
    end
  end

  test "direction badge colours match the shared parity table" do
    for %{"badge" => badge, "color" => color} <- @vectors["direction_badges"] do
      assert StreamdeckKeyFaceContract.direction_badge!(badge) == %{"color" => color}
    end
  end

  test "footer variants match the shared parity table" do
    for vector <- @vectors["footers"] do
      footer =
        case vector["dependency_ready"] do
          "absent" -> StreamdeckKeyFaceContract.footer_for_agent(vector["bucket"], %{})
          ready -> StreamdeckKeyFaceContract.footer(vector["bucket"], ready)
        end

      assert footer == %{kind: vector["kind"], label: vector["label"], dependency: vector["dependency"]}
    end
  end

  test "unknown states and badges fail closed instead of rendering a default" do
    assert_raise ArgumentError, ~r/unhandled Stream Deck key state/, fn -> StreamdeckKeyFaceContract.state!(:unknown) end
    assert_raise ArgumentError, ~r/unhandled Stream Deck key state/, fn -> StreamdeckKeyFaceContract.bucket_rank!("unknown") end
    assert_raise ArgumentError, ~r/unhandled Stream Deck direction badge/, fn -> StreamdeckKeyFaceContract.direction_badge!("UNKNOWN") end
    refute StreamdeckKeyFaceContract.known_state?(:unknown)
  end
end
