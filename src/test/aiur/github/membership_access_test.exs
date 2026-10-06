defmodule Aiur.GitHub.MembershipAccessTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.GithubWebhook
  alias Aiur.GitHub.ResourceStore

  @repo "membership-timeout/repo"

  setup do
    unless Process.whereis(ResourceStore), do: start_supervised!({ResourceStore, path: nil})
    :ok
  end

  @tag timeout: 45_000
  test "a busy owner cannot confirm unapplied membership writes or a webhook deposit" do
    key = ResourceStore.key_for_repo(:sub_issue, @repo, "1:2")
    ResourceStore.put_resource(key, %{"present" => true}, version: "before")
    owner = :ets.info(ResourceStore.Table, :owner)
    :ok = :sys.suspend(owner)

    payload = %{
      "repository" => %{"full_name" => @repo},
      "action" => "sub_issue_removed",
      "parent_issue_number" => 1,
      "sub_issue_number" => 2
    }

    operations = [
      update: fn -> ResourceStore.update_resource(key, fn _ -> %{"present" => false} end) end,
      put: fn -> ResourceStore.put_resource(key, %{"present" => false}) end,
      forget: fn -> ResourceStore.forget(key) end,
      clear: fn -> ResourceStore.clear(:sub_issue, "membership-timeout", "repo") end,
      delivery: fn ->
        GithubWebhook.handle_delivery("sub_issues", payload,
          repo: @repo,
          server: :membership_test_no_webhooks
        )
      end
    ]

    try do
      results =
        operations
        |> Enum.map(fn {name, operation} -> {name, Task.async(fn -> outcome(operation) end)} end)
        |> Enum.map(fn {name, task} -> {name, Task.await(task, 35_000)} end)
        |> Map.new()

      for name <- [:update, :put, :forget, :clear] do
        assert {:exit, {:membership_unavailable, {:timeout, _call}}} = results[name]
      end

      assert %{status: :error, reason: {:exit, {:membership_unavailable, {:timeout, _call}}}} = results.delivery
      # Timeout does not cancel the queued calls. Crucially, none has been
      # acknowledged as complete while the held body is still unchanged.
      assert [{^key, %{data: %{"present" => true}}}] = :ets.lookup(ResourceStore.Table, key)
    after
      :sys.resume(owner)
      # Barrier: drain this test's queued calls before releasing the store.
      :sys.get_state(owner)
      ResourceStore.clear(:sub_issue, "membership-timeout", "repo")
    end
  end

  defp outcome(operation) do
    operation.()
  catch
    :exit, reason -> {:exit, reason}
  end
end
