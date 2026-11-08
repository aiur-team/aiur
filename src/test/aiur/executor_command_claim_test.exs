defmodule Aiur.ExecutorCommandClaimTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Aiur.ExecutorCommandCLI

  @id "dec_0123456789abcdef"
  @now ~U[2026-11-06 12:00:00Z]
  @expires DateTime.add(@now, 1800, :second)

  defp no_store, do: [record_fact_fun: fn _, _, _, _ -> flunk("invalid input reached store") end]

  test "usage errors exit 64 without touching the store" do
    for params <- [
          [decision_id: "bad", executor_id: "exec-a"],
          [decision_id: @id],
          [decision_id: @id, executor_id: "bad executor"],
          [decision_id: @id, executor_id: "aiur-cli"],
          [decision_id: @id, executor_id: "exec-a", ttl_s: 0]
        ] do
      assert capture_io(:stderr, fn -> assert ExecutorCommandCLI.claim(params, no_store()) == 64 end) =~ "executor-claim-decision"
    end
  end

  test "a claim held by another Executor exits 1 naming the claimant" do
    writer = fn _, :executor_claimed, _, _ -> {:error, {:invalid_transition, {:claimed, "exec-a", @expires}}} end
    err = capture_io(:stderr, fn -> assert ExecutorCommandCLI.claim([decision_id: @id, executor_id: "exec-b"], record_fact_fun: writer, now: @now) == 1 end)
    assert err =~ "claimed by exec-a until 2026-11-06T12:30:00Z"
  end

  test "a successful claim writes the TTL expiry and prints claimed" do
    test = self()
    writer = fn id, type, data, _ -> send(test, {:fact, id, type, data}) && {:ok, %{status: :accepted}} end
    out = capture_io(fn -> assert ExecutorCommandCLI.claim([decision_id: @id, executor_id: "exec-a"], record_fact_fun: writer, now: @now) == 0 end)
    assert out == "claimed #{@id}\n"
    assert_received {:fact, @id, :executor_claimed, %{executor_id: "exec-a", at: @now, expires_at: @expires}}
  end

  test "release writes a release fact for the claimant" do
    test = self()
    writer = fn id, type, data, _ -> send(test, {:fact, id, type, data}) && {:ok, %{status: :accepted}} end
    out = capture_io(fn -> assert ExecutorCommandCLI.release([decision_id: @id, executor_id: "exec-a"], record_fact_fun: writer, now: @now) == 0 end)
    assert out == "released #{@id}\n"
    assert_received {:fact, @id, :executor_claim_released, %{executor_id: "exec-a", reason: :released}}
  end

  test "an Executor's answer on a claimed Command is refused naming the claimant" do
    answer_fun = fn _, _, _, _ -> {:error, {:claimed, "exec-a", @expires}} end
    params = [decision_id: @id, expected_version: 1, option_id: "x", rationale: "r", idempotency_key: "k", executor_id: "exec-b"]
    err = capture_io(:stderr, fn -> assert ExecutorCommandCLI.answer(params, answer_fun: answer_fun, decision_store: :s) == 1 end)
    assert err =~ "claimed by exec-a until 2026-11-06T12:30:00Z"
  end
end
