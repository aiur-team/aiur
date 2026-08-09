defmodule AiurWeb.StreamdeckKeyFaceContractTest do
  use ExUnit.Case, async: true

  alias AiurWeb.StreamdeckKeyFaceContract

  test "queued footer is fail closed for absent or non-true readiness" do
    assert StreamdeckKeyFaceContract.footer_for_agent(:queued, %{}) == %{
             kind: "queued",
             label: "Unstarted",
             dependency: "Blocked"
           }

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
end
