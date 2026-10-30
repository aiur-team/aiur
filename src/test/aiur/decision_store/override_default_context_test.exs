defmodule Aiur.DecisionStore.OverrideDefaultContextTest do
  use Aiur.TestSupport

  alias Aiur.DecisionStore.OverridePushes

  defmodule HeldOnlyTracker do
    def ticket_pull_request(identifier) do
      send(self(), {:held_pr_read, identifier})
      {:ok, nil}
    end

    def issue_closure(_, _), do: raise("the periodic default reader must not resolve closure remotely")
    def resolve_ticket_pull_request(_, _), do: raise("the periodic default reader must not resolve a merge remotely")
  end

  test "future regression guard: the default context reader uses only the delivered PR capability on a cache miss" do
    previous = Application.fetch_env!(:aiur, :tracker_adapters)
    Application.put_env(:aiur, :tracker_adapters, Map.new(previous, fn {kind, _} -> {kind, HeldOnlyTracker} end))
    on_exit(fn -> Application.put_env(:aiur, :tracker_adapters, previous) end)
    assert OverridePushes.context("50") == %{pr: :unknown}
    assert_received {:held_pr_read, "50"}
  end
end
