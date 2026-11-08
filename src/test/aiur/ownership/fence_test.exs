defmodule Aiur.Ownership.FenceTest do
  use ExUnit.Case, async: true

  alias Aiur.Ownership.{Fence, FenceCommand, Record}

  @mine %Record{
    schema: "aiur.ownership/v1",
    repo: "o/r",
    ticket: "42",
    state: "owned",
    gateway_id: "aaaaaaaaaaaaaaaaaaaaaaaaaa",
    gateway_label: "mine",
    daemon_key: "k1",
    epoch: 3,
    previous_epoch: 2,
    actor: %{kind: "daemon", id: "k1"},
    reason: "dispatch",
    at: "2026-11-08T00:00:00Z"
  }

  # The stub serves `ref` (an Agent holding the current record or an error) and counts reads.
  defp start_fence(ref) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    read = fn "o/r", "42", [] ->
      Agent.update(counter, &(&1 + 1))

      case Agent.get(ref, & &1) do
        {:error, why} -> {:unknown, why}
        record -> {:ok, %{record: record, oid: "x", repository_id: "r"}}
      end
    end

    test_pid = self()
    notify = fn id, epoch -> send(test_pid, {:ownership_moved, id, epoch}) end
    {:ok, fence} = Fence.start_link(name: nil, read_fun: read, notify: notify)
    :ok = Fence.register(%{identifier: "42"}, @mine, fence)
    {fence, counter}
  end

  defp check(fence, now), do: Fence.check("42", server: fence, now_ms: now)

  test "an agent started at epoch 3 is moved once the ref is at epoch 4" do
    {:ok, ref} = Agent.start_link(fn -> %{@mine | epoch: 4} end)
    {fence, _} = start_fence(ref)
    assert {:moved, %{epoch: 4, owner: "mine", state: "owned"}} = check(fence, 0)
  end

  test "an unchanged owner passes, a different daemon or a release does not" do
    {:ok, ref} = Agent.start_link(fn -> @mine end)
    {fence, _} = start_fence(ref)
    assert {:ok, %{epoch: 3}} = check(fence, 0)

    Agent.update(ref, fn _ -> %{@mine | daemon_key: "k2"} end)
    assert {:moved, _} = check(fence, 30_001)

    Agent.update(ref, fn _ -> %{@mine | state: "released", epoch: 5} end)
    assert {:moved, %{owner: "-", epoch: 5, state: "released"}} = check(fence, 60_003)
  end

  test "a read is reused for 30 s and refreshed after" do
    {:ok, ref} = Agent.start_link(fn -> @mine end)
    {fence, counter} = start_fence(ref)
    assert {:ok, _} = check(fence, 1_000)
    Agent.update(ref, fn _ -> %{@mine | epoch: 4} end)
    assert {:ok, _} = check(fence, 31_000)
    assert Agent.get(counter, & &1) == 1
    assert {:moved, %{epoch: 4}} = check(fence, 31_001)
    assert Agent.get(counter, & &1) == 2
  end

  test "a failed read fails closed and is not cached" do
    {:ok, ref} = Agent.start_link(fn -> {:error, :timeout} end)
    {fence, counter} = start_fence(ref)
    assert {:unknown, {:read_failed, :timeout}} = check(fence, 0)
    Agent.update(ref, fn _ -> @mine end)
    assert {:ok, _} = check(fence, 1)
    assert Agent.get(counter, & &1) == 2
  end

  test "an unregistered workspace is unknown" do
    {:ok, ref} = Agent.start_link(fn -> @mine end)
    {fence, _} = start_fence(ref)
    assert {:unknown, :no_registration} = Fence.check("43", server: fence)
  end

  test "a moved ref notifies the orchestrator once per ticket and epoch" do
    {:ok, ref} = Agent.start_link(fn -> %{@mine | epoch: 4} end)
    {fence, _} = start_fence(ref)
    assert {:moved, _} = check(fence, 0)
    assert {:moved, _} = check(fence, 1)
    assert_received {:ownership_moved, "42", 3}
    refute_received {:ownership_moved, _, _}
  end

  test "an unchanged owner does not notify" do
    {:ok, ref} = Agent.start_link(fn -> @mine end)
    {fence, _} = start_fence(ref)
    assert {:ok, _} = check(fence, 0)
    refute_received {:ownership_moved, _, _}
  end

  test "a finished run's workspace answers no_registration" do
    {:ok, ref} = Agent.start_link(fn -> @mine end)
    {fence, _} = start_fence(ref)
    assert {:ok, _} = check(fence, 0)
    Fence.unregister("42", fence)
    assert {:unknown, :no_registration} = check(fence, 1)
  end

  test "command output separates moved from unknown from a bad request" do
    {:ok, ref} = Agent.start_link(fn -> %{@mine | epoch: 4} end)
    {fence, _} = start_fence(ref)
    args = ["fence", "--workspace", "/w/42", "--action", "push"]
    assert {:ok, "moved owner=mine epoch=4 state=owned\n"} = FenceCommand.execute(args, server: fence)
    assert {:ok, "unknown no_registration\n"} = FenceCommand.execute(["fence", "--workspace", "/w/7", "--action", "push"], server: fence)
    assert {:error, :invalid_request} = FenceCommand.execute(["fence", "--workspace", "/w/42", "--action", "rm"], server: fence)
  end
end
