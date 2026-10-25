defmodule Aiur.OptimisticStart.RecordTest do
  use ExUnit.Case, async: true

  alias Aiur.OptimisticStart

  @sha String.duplicate("a", 40)
  @other_sha String.duplicate("b", 40)

  test "one blocker selects its branch as PR base and start point" do
    assert {:ok, record} = OptimisticStart.from_gate_evidence([evidence("12")], fn _ -> nil end)
    assert record.primary == "12"
    assert record.pr_base == "refs/heads/aiur/12-work"
    assert record.blockers == [%{identifier: "12", pr_number: 99, ref: record.pr_base, sha: @sha}]
    assert %DateTime{} = record.started_at
    assert OptimisticStart.start_point(record) == %{ref: record.pr_base, sha: @sha}
  end

  test "fan-in keeps all blocker heads but starts on the base" do
    assert {:ok, record} = OptimisticStart.from_gate_evidence([evidence("12"), evidence("13")], fn _ -> nil end)
    assert record.primary == nil
    assert record.pr_base == :base_branch
    assert Enum.map(record.blockers, & &1.identifier) == ["12", "13"]
    assert OptimisticStart.start_point(record) == nil
  end

  test "missing SHA uses the complete validated fallback pair" do
    fallback = %{ref: "refs/heads/aiur/12-new-work", sha: @other_sha}
    lookup = fn "12" -> fallback end
    assert {:ok, record} = OptimisticStart.from_gate_evidence([%{evidence("12") | head_sha: nil}], lookup)
    assert [%{ref: "refs/heads/aiur/12-new-work", sha: @other_sha}] = record.blockers
  end

  test "missing or unsafe evidence declines when the fallback is unavailable" do
    for changes <- [%{head_sha: nil}, %{head_ref: "aiur/12-work\n$(echo injected)"}, %{head_ref: "aiur/13-work"}, %{head_sha: "not-a-sha"}] do
      assert {:error, :optimistic_ref_unavailable} = OptimisticStart.from_gate_evidence([Map.merge(evidence("12"), changes)], fn _ -> nil end)
    end
  end

  test "empty evidence is an ordinary dispatch" do
    assert {:ok, nil} = OptimisticStart.from_gate_evidence([], fn _ -> flunk("must not look up refs") end)
    assert OptimisticStart.start_point(nil) == nil
  end

  defp evidence(identifier), do: %{identifier: identifier, pr_number: 99, head_ref: "aiur/#{identifier}-work", head_sha: @sha}
end
