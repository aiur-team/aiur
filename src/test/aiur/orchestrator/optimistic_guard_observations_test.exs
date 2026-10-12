defmodule Aiur.Orchestrator.OptimisticGuardObservationsTest do
  use ExUnit.Case, async: true
  alias Aiur.Issue
  alias Aiur.Orchestrator.{OptimisticGuard, OptimisticGuardObservations}
  @now 1_000_000

  test "empty and closed ledger performs no tracker or code host reads" do
    assert OptimisticGuardObservations.read([record()], @now, opts([]))["10"].pr_number == 100
    opts = opts(fetch_issues: &unexpected/1, blocked_by: &unexpected/1, closure: &unexpected/2, read_pr: &unexpected/2)
    assert OptimisticGuardObservations.read([], @now, opts) == %{dependents: %{}}
    assert OptimisticGuardObservations.read([Map.put(record(), "status", "closed")], @now, opts) == %{dependents: %{}}
  end

  test "fresh durable observations reuse both PR and edge evidence" do
    opts = opts(fetch_issues: &unexpected/1, blocked_by: &unexpected/1, closure: &unexpected/2, read_pr: &unexpected/2)
    assert %{"10" => fresh} = OptimisticGuardObservations.read([record(cached())], @now, opts)
    assert fresh.confirmed?
    assert fresh.observed_at_ms == @now - 100
    assert fresh.edges["11"] == MapSet.new(["10"])
    assert fresh.pr_number == 100
  end

  test "refresh fetches only stale blockers and reuses poll-held issues" do
    row = Map.update!(record(cached()), "blockers", &(&1 ++ [%{"id" => "12", "pr_number" => 120}]))
    pid = self()

    opts =
      opts(
        fetch_issues: fn ids ->
          send(pid, {:fetched, ids})
          {:ok, [%Issue{identifier: "12", labels: ["aiur:error"]}]}
        end,
        read_pr: fn id, number ->
          send(pid, {:read_pr, id, number})
          {:ok, pr(number)}
        end,
        label_prefix: "aiur"
      )

    observed = OptimisticGuardObservations.read([row], @now, opts)
    assert_receive {:fetched, ["12"]}, 500
    assert_receive {:read_pr, "12", 120}, 500
    refute_receive {:read_pr, "10", _}, 100
    assert observed["12"].labels == ["agent:error"]
    opts = opts(issues: %{"10" => %Issue{identifier: "10", labels: ["agent:todo"]}}, fetch_issues: &unexpected/1)
    assert %{"10" => %{labels: ["agent:todo"]}} = OptimisticGuardObservations.read([record()], @now, opts)
  end

  test "poll-held recovery clears cached trouble without another PR read" do
    row = record(Map.put(cached(), "labels", ["agent:error"]))
    opts = opts(issues: %{"10" => %Issue{identifier: "10", labels: ["agent:in-progress"]}}, fetch_issues: &unexpected/1, read_pr: &unexpected/2, closure: &unexpected/2)
    observations = OptimisticGuardObservations.read([row], @now, opts)
    assert observations["10"].labels == ["agent:in-progress"]
    assert {:resolve, :optimistic_blocker_failed, "11"} in OptimisticGuard.decide([row], observations, @now)
  end

  test "missing blocker from poll map is fetched even with supplied poll issues" do
    pid = self()

    opts =
      opts(
        issues: %{"99" => %Issue{identifier: "99"}},
        fetch_issues: fn ids ->
          send(pid, {:fetched, ids})
          {:ok, [%Issue{identifier: "10", labels: ["agent:error"]}]}
        end
      )

    observations = OptimisticGuardObservations.read([record()], @now, opts)
    assert_receive {:fetched, ["10"]}, 500
    assert observations["10"].confirmed? == true
    assert observations["10"].labels == ["agent:error"]
  end

  test "forced and expired PR observations read confirming PR despite held evidence" do
    pid = self()

    opts =
      opts(
        read_pr: fn id, number ->
          send(pid, {:read_pr, id})
          {:ok, pr(number)}
        end,
        force_blocker: "10"
      )

    assert %{"10" => %{observed_at_ms: @now}} = OptimisticGuardObservations.read([record(cached())], @now, opts)
    assert_receive {:read_pr, "10"}, 500
    expired = Map.put(cached(), "observed_at_ms", @now - 120_000)
    assert %{"10" => %{observed_at_ms: @now}} = OptimisticGuardObservations.read([record(expired)], @now, opts(read_pr: opts[:read_pr]))
    assert_receive {:read_pr, "10"}, 500
  end

  test "grace crossing confirms replacement opened after the cached closure" do
    now = 630_000
    observation = Map.merge(cached(), %{"observed_at_ms" => 600_000, "pr_state" => "closed", "any_open_pr?" => false})
    row = record(observation) |> put_in(["blockers", Access.at(0), "suspect_since_ms"], 10_000) |> put_in(["blockers", Access.at(0), "suspect_cause"], "pr_closed_unmerged")
    pid = self()

    opts =
      opts(
        grace_ms: 600_000,
        read_pr: fn _, _ ->
          send(pid, :confirmed_replacement)
          {:ok, Map.put(pr(200), "created_at", "1970-01-01T00:10:05Z")}
        end
      )

    observations = OptimisticGuardObservations.read([row], now, opts)
    assert_receive :confirmed_replacement, 500
    assert observations["10"].pr_number == 200
    assert observations["10"].observed_at_ms == now
    refute Enum.any?(OptimisticGuard.decide([row], observations, now, grace_ms: 600_000), &match?({:park, _, _, _}, &1))
  end

  test "grace crossing confirms recovered labels despite a stale poll snapshot" do
    observation = Map.merge(cached(), %{"observed_at_ms" => 600_000, "labels" => ["agent:error"]})
    row = record(observation) |> put_in(["blockers", Access.at(0), "suspect_since_ms"], 10_000) |> put_in(["blockers", Access.at(0), "suspect_cause"], "agent_error")
    old_issue = %Issue{identifier: "10", labels: ["agent:error"]}
    observations = OptimisticGuardObservations.read([row], 630_000, opts(grace_ms: 600_000, issues: %{"10" => old_issue}))
    assert observations["10"].labels == []
    refute Enum.any?(OptimisticGuard.decide([row], observations, 630_000, grace_ms: 600_000), &match?({:attention, _, _, _}, &1))
  end

  test "merged confirming PR cannot park from an apparent closed unmerged event" do
    opts = opts(read_pr: fn _, _ -> {:ok, Map.merge(pr(100), %{"state" => "closed", "merged" => true})} end)
    observations = OptimisticGuardObservations.read([record()], @now, opts)
    assert observations["10"].pr_merged == true
    refute Enum.any?(OptimisticGuard.decide([record()], observations, @now), &match?({:park, _, _, _}, &1))
  end

  test "raising closure, PR and issue readers leave the observation unconfirmed" do
    failures = [closure: fn _, _ -> raise "closure unavailable" end, read_pr: fn _, _ -> raise "PR unavailable" end, fetch_issues: fn _ -> raise "issues unavailable" end]

    for failure <- failures do
      observations = OptimisticGuardObservations.read([record()], @now, opts([failure]))
      assert observations["10"].confirmed? == false
      assert OptimisticGuard.decide([record()], observations, @now) == []
    end
  end

  test "raising or exiting edge readers retain unknown edges without parking" do
    for read <- [fn _ -> raise "edge unavailable" end, fn _ -> exit(:noproc) end] do
      observations = OptimisticGuardObservations.read([record()], @now, opts(blocked_by: read))
      assert observations["10"].edges["11"] == :unknown
      refute Enum.any?(OptimisticGuard.decide([record()], observations, @now), &match?({:park, _, _, _}, &1))
    end
  end

  test "failed closure, PR or issue reads fail closed" do
    for failure <- [opts(closure: fn _, _ -> {:error, :unavailable} end), opts(read_pr: fn _, _ -> {:error, :unavailable} end), opts(fetch_issues: fn _ -> {:error, :unavailable} end)] do
      observations = OptimisticGuardObservations.read([record()], @now, failure)
      assert observations["10"].confirmed? == false
      assert OptimisticGuard.decide([record()], observations, @now) == []
    end
  end

  test "expired edge rechecks; failed edge stays unknown; confirmed removal parks" do
    row = put_in(record(cached()), ["blockers", Access.at(0), "guard_observation", "edge_cache", "11", "observed_at_ms"], @now - 120_000)
    observations = OptimisticGuardObservations.read([row], @now, opts(blocked_by: fn _ -> {:error, :unavailable} end))
    assert observations["10"].edges["11"] == :unknown
    assert observations["10"].edge_cache == %{}
    refute Enum.any?(OptimisticGuard.decide([row], observations, @now), &match?({:park, _, _, _}, &1))
    observations = OptimisticGuardObservations.read([row], @now, opts(blocked_by: fn _ -> {:ok, []} end))
    assert {:park, "11", "10", :edge_removed} in OptimisticGuard.decide([row], observations, @now)
  end

  test "parked dependent labels are confirmed despite a pre-park poll snapshot" do
    row = Map.put(record(cached()), "status", "parked")
    old = %Issue{identifier: "11", labels: []}
    current = %Issue{identifier: "11", labels: ["agent:parked"]}
    pid = self()

    observations =
      OptimisticGuardObservations.read(
        [row],
        @now,
        opts(
          issues: %{"11" => old},
          fetch_issues: fn ids ->
            send(pid, {:fetched, ids})
            {:ok, [current]}
          end
        )
      )

    assert_receive {:fetched, ["11"]}, 500
    assert observations.dependents == %{"11" => current}
  end

  test "failed dependent confirmation cannot turn stale poll labels into an unpark" do
    row = Map.put(record(cached()), "status", "parked")
    old = %Issue{identifier: "11", labels: []}
    observations = OptimisticGuardObservations.read([row], @now, opts(issues: %{"11" => old}, fetch_issues: fn ["11"] -> {:error, :offline} end))
    assert observations.dependents == %{}
  end

  defp opts(extra) do
    Keyword.merge(
      [
        observation_max_age_ms: 120_000,
        fetch_issues: fn _ -> {:ok, [%Issue{identifier: "10", labels: []}]} end,
        blocked_by: fn _ -> {:ok, ["10"]} end,
        closure: fn _, _ -> {:ok, %{open?: true, state_reason: nil}} end,
        read_pr: fn _, number -> {:ok, pr(number)} end
      ],
      extra
    )
  end

  defp unexpected(_), do: flunk("unexpected confirming read")
  defp unexpected(_, _), do: flunk("unexpected confirming read")
  defp pr(number), do: %{"number" => number, "state" => "open", "merged" => false, "head" => %{"ref" => "aiur/10", "sha" => "head"}}

  defp cached,
    do: %{
      "confirmed?" => true,
      "observed_at_ms" => @now - 100,
      "issue_open?" => true,
      "labels" => [],
      "pr_state" => "open",
      "pr_merged" => false,
      "any_open_pr?" => true,
      "pr_number" => 100,
      "edge_cache" => %{"11" => %{"ids" => ["10"], "observed_at_ms" => @now - 100}}
    }

  defp record(observation \\ nil),
    do: %{"ticket" => "11", "status" => "running", "blockers" => [%{"id" => "10", "pr_number" => 100, "guard_observation" => observation}], "counters" => %{"integrations_conflict" => 0}}
end
