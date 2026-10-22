defmodule Aiur.LandingWatch.PrRerunRefreshTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.PrRerun

  test "base recovery updates the still-approved observed PR head instead of rerunning its stale merge ref" do
    parent = self()
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    started = now - 120_000
    recovered = now - 30_000

    history = [
      %{completed_at: started - 10_000, checks: [%{name: "ci gate", conclusion: "failure"}]},
      %{completed_at: recovered, checks: [%{name: "ci gate", conclusion: "success"}]}
    ]

    observation = %{
      number: 17,
      head: "approved-head",
      review_decision: "APPROVED",
      reviews: [%{"commit" => %{"oid" => "approved-head"}}]
    }

    failed = %{
      "run_id" => 99,
      "status" => "completed",
      "conclusion" => "failure",
      "started_at" => DateTime.from_unix!(started, :millisecond) |> DateTime.to_iso8601(),
      "name" => "ci gate"
    }

    opts = [
      now_ms: now,
      main_history_fun: fn -> history end,
      update_branch_fun: fn 17, "approved-head", _ ->
        send(parent, :updated_approved_head)
        {:ok, %{}}
      end,
      observe_refresh_fun: fn 17, _ -> {:ok, %{"headRefOid" => "refreshed-head"}} end,
      approval_carry_classifier: fn "approved-head", "refreshed-head", 17, _ ->
        send(parent, :approval_carry_checked)
        :identical
      end,
      comment_fun: fn 17, body, _ ->
        send(parent, {:comment, body})
        {:ok, %{}}
      end,
      journal_path: journal_path()
    ]

    assert :ok = PrRerun.recover_main_ci(observation, [failed], {started - 1, recovered}, opts)
    assert_received :updated_approved_head
    assert_received :approval_carry_checked
    assert_received {:comment, body}
    assert body =~ "merge ref predates a fix on the base branch"
    refute_received {:rerun, _}
  end

  test "base refresh refuses to claim approval carry when the contribution changed" do
    parent = self()
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    started = now - 120_000
    recovered = now - 30_000

    history = [
      %{completed_at: started - 10_000, checks: [%{name: "ci gate", conclusion: "failure"}]},
      %{completed_at: recovered, checks: [%{name: "ci gate", conclusion: "success"}]}
    ]

    observation = %{number: 18, head: "approved-head", review_decision: "APPROVED", reviews: [%{"commit" => %{"oid" => "approved-head"}}]}
    failed = %{"run_id" => 100, "status" => "completed", "conclusion" => "failure", "started_at" => DateTime.from_unix!(started, :millisecond) |> DateTime.to_iso8601(), "name" => "ci gate"}

    opts = [
      now_ms: now,
      main_history_fun: fn -> history end,
      update_branch_fun: fn _, _, _ -> {:ok, %{}} end,
      observe_refresh_fun: fn _, _ -> {:ok, %{"headRefOid" => "refreshed-head"}} end,
      approval_carry_classifier: fn _, _, _, _ -> {:changed, %{reason: :contribution_changed, hunks: []}} end,
      comment_fun: fn _, _, _ ->
        send(parent, :incorrectly_claimed_carry)
        {:ok, %{}}
      end,
      journal_path: journal_path()
    ]

    assert {:error, {:approval_not_carried, %{reason: :contribution_changed}}} = PrRerun.recover_main_ci(observation, [failed], {started - 1, recovered}, opts)
    refute_received :incorrectly_claimed_carry
  end

  defp journal_path do
    path = Path.join(System.tmp_dir!(), "landing-refresh-#{System.unique_integer([:positive])}.json")
    ExUnit.Callbacks.on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    path
  end
end
