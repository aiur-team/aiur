defmodule AiurWeb.StreamdeckKeyFaceContractTest do
  use ExUnit.Case, async: true

  alias AiurWeb.StreamdeckKeyFaceContract

  test "queued footer is fail closed for absent or non-true readiness" do
    assert StreamdeckKeyFaceContract.footer_for_agent(:queued, %{}) == %{
             kind: "queued",
             label: "Queued",
             dependency: "Blocked"
           }

    assert StreamdeckKeyFaceContract.footer_for_agent(:queued, %{dependency_ready: nil}).dependency == "Blocked"
    assert StreamdeckKeyFaceContract.footer_for_agent(:queued, %{dependency_ready: false}).dependency == "Blocked"
    assert StreamdeckKeyFaceContract.footer_for_agent(:queued, %{dependency_ready: "true"}).dependency == "Blocked"
    assert StreamdeckKeyFaceContract.footer_for_agent(:queued, %{dependency_ready: true}).dependency == "Unblocked"
  end

  test "non-queued footer does not expose dependency state" do
    assert StreamdeckKeyFaceContract.footer_for_agent(:running, %{}) == %{
             kind: "progress",
             label: "Running",
             dependency: nil
           }
  end

  test "labels match the deck renderer's bucket labels" do
    assert Enum.map([:alert, :stuck, :running, :paused, :queued], &StreamdeckKeyFaceContract.label!/1) ==
             ["Alert", "Stuck", "Running", "Paused", "Queued"]
  end

  test "an unknown bucket has no label rather than a default one" do
    refute StreamdeckKeyFaceContract.known_state?(:merged)
    assert_raise ArgumentError, fn -> StreamdeckKeyFaceContract.label!(:merged) end
  end
end
