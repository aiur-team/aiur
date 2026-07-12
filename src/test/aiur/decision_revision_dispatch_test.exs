defmodule Aiur.DecisionRevisionDispatchTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionRevisionDispatch, Issue}

  @decision %{
    ticket: %{
      identifier: "tracker-id-985",
      title: "OCC-8",
      url: "https://github.com/its-everdred/aiur/issues/985"
    }
  }
  @terminal_states MapSet.new(["done", "canceled"])

  describe "revalidate_target/2" do
    test "uses the trusted Decision ticket identity for a fresh lookup" do
      parent = self()

      revalidator = fn %Issue{} = issue, fetcher, terminal_states ->
        send(parent, {:revalidated, issue, fetcher, terminal_states})
        {:ok, %Issue{issue | state: "in-progress"}}
      end

      fetcher = fn _ids -> {:ok, []} end

      assert {:ok, refreshed} =
               revalidate(revalidate_fun: revalidator, issue_fetcher: fetcher)

      assert refreshed.state == "in-progress"

      assert_receive {:revalidated, issue, ^fetcher, @terminal_states}
      assert issue.id == "tracker-id-985"
      assert issue.identifier == "tracker-id-985"
      assert issue.title == "OCC-8"
    end

    test "classifies a freshly missing target as no longer applicable" do
      revalidator = fn _issue, _fetcher, _terminal_states -> {:skip, :missing} end

      assert revalidate(revalidate_fun: revalidator) ==
               {:no_longer_applicable, :missing}
    end

    test "classifies a terminal target as no longer applicable" do
      target = %Issue{id: "tracker-id-985", identifier: "985", state: "Done"}
      revalidator = fn _issue, _fetcher, _terminal_states -> {:skip, target} end

      assert revalidate(revalidate_fun: revalidator) ==
               {:no_longer_applicable, {:terminal, "Done"}}
    end

    test "keeps a paused non-terminal target applicable for existing wake gates" do
      target = %Issue{id: "tracker-id-985", identifier: "985", state: "In Progress", paused: true}
      revalidator = fn _issue, _fetcher, _terminal_states -> {:skip, target} end

      assert revalidate(revalidate_fun: revalidator) == {:ok, target}
    end

    test "keeps tracker failures retryable" do
      revalidator = fn _issue, _fetcher, _terminal_states -> {:error, :tracker_unavailable} end

      assert revalidate(revalidate_fun: revalidator) ==
               {:error, {:target_revalidation_failed, :tracker_unavailable}}
    end

    test "fails closed without a durable target identity" do
      assert DecisionRevisionDispatch.revalidate_target(%{ticket: %{identifier: nil}},
               terminal_states: @terminal_states
             ) == {:error, :target_identity_missing}
    end
  end

  defp revalidate(overrides) do
    defaults = [
      issue_fetcher: fn _ids -> {:ok, []} end,
      terminal_states: @terminal_states
    ]

    DecisionRevisionDispatch.revalidate_target(@decision, Keyword.merge(defaults, overrides))
  end
end
