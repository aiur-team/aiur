defmodule Aiur.Ownership.LivenessTest do
  use ExUnit.Case, async: true

  alias Aiur.Ownership.Liveness

  @owner %{gateway_id: "aaaaaaaaaaaaaaaaaaaaaaaaaa"}
  @threshold 180_000

  defp roster(ages, id \\ @owner.gateway_id), do: {:ok, %{instances: Enum.map(ages, &%{gateway_id: id, age_ms: &1})}}
  defp evidence(roster, hello \\ :unreachable, self? \\ false), do: %{self?: self?, roster: roster, hello: hello}

  test "a row exactly at the threshold is online, one millisecond past it is offline" do
    assert %{status: :online, source: :heartbeat} = Liveness.classify(@owner, evidence(roster([180_000])), @threshold)
    assert %{status: :offline, source: :heartbeat, age_ms: 180_001} = Liveness.classify(@owner, evidence(roster([180_001])), @threshold)
  end

  test "the freshest of several rows decides" do
    assert %{status: :online, age_ms: 20_000} = Liveness.classify(@owner, evidence(roster([600_000, 20_000])), @threshold)
  end

  test "an absent row, a store error and no store are unknown, never offline" do
    for roster <- [roster([], "bbbbbbbbbbbbbbbbbbbbbbbbbb"), {:error, :down}, :disabled] do
      assert %{status: :unknown, source: nil, age_ms: nil} = Liveness.classify(@owner, evidence(roster), @threshold)
    end
  end

  test "a stale row with an answering hello is online via hello" do
    assert %{status: :online, source: :hello} = Liveness.classify(@owner, evidence(roster([600_000]), :alive), @threshold)
  end

  test "hello alone, with the store down, is online" do
    assert %{status: :online, source: :hello} = Liveness.classify(@owner, evidence({:error, :down}, :alive), @threshold)
  end

  test "this daemon is online via self" do
    assert %{status: :online, source: :self} = Liveness.classify(@owner, evidence(:disabled, :unreachable, true), @threshold)
  end

  test "gather asks the roster and hello, and self" do
    owner = Map.put(@owner, :marker, 1)

    assert %{self?: true, hello: :alive, roster: :disabled} =
             Liveness.gather(owner, roster_fun: fn -> :disabled end, hello_fun: fn ^owner -> :alive end, self_fun: fn -> true end)
  end
end
