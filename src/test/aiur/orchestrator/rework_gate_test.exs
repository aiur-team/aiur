defmodule Aiur.Orchestrator.ReworkGateTest do
  # `use Aiur.TestSupport` expands to `use ExUnit.Case` without `async: true`;
  # the availability tests inspect the tracker adapter, which reads global
  # config and cannot race async cases.
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{ReworkGate, State}

  # #2075: `rework` means "work exists and was rejected", so every rework
  # transition must first verify an open pull request exists. This module is
  # the single source of that precondition: a closed or absent PR refuses the
  # transition at the source (`{:skip, :no_open_pr}`), a transient lookup
  # failure surfaces for the caller to retry or park, and only an open PR
  # yields `:ok`.
  describe "verify_open_pr/2" do
    test "returns :ok when an open pull request exists" do
      assert ReworkGate.verify_open_pr("2075", open_pr_fetcher: fn _ -> {:ok, %{number: 42}} end) == :ok
    end

    test "refuses when no open pull request exists (closed or absent)" do
      assert ReworkGate.verify_open_pr("2075", open_pr_fetcher: fn _ -> {:ok, nil} end) == {:skip, :no_open_pr}
      assert ReworkGate.verify_open_pr("2075", open_pr_fetcher: fn _ -> {:ok, []} end) == {:skip, :no_open_pr}
    end

    test "surfaces a transient lookup failure for the caller to retry or park" do
      assert ReworkGate.verify_open_pr("2075", open_pr_fetcher: fn _ -> {:error, :timeout} end) == {:error, :timeout}
    end
  end

  describe "open_pr/2" do
    test "returns the open pull request when one exists" do
      pr = %{"number" => 42}
      assert ReworkGate.open_pr("2075", open_pr_fetcher: fn _ -> {:ok, pr} end) == {:ok, pr}
    end

    test "refuses when no open pull request exists (closed or absent)" do
      assert ReworkGate.open_pr("2075", open_pr_fetcher: fn _ -> {:ok, nil} end) == {:skip, :no_open_pr}
      assert ReworkGate.open_pr("2075", open_pr_fetcher: fn _ -> {:ok, []} end) == {:skip, :no_open_pr}
    end

    test "surfaces a transient lookup failure for the caller to retry or park" do
      assert ReworkGate.open_pr("2075", open_pr_fetcher: fn _ -> {:error, :timeout} end) == {:error, :timeout}
    end
  end

  # #2422 / #2450: `rework` is only justified while a reviewer is actually
  # asking for a change, and the only signal that reliably answers that is
  # unresolved review threads — GitHub's `reviewDecision` never clears when
  # findings are addressed, so a `CHANGES_REQUESTED` verdict cannot distinguish
  # "outstanding findings" from "was once told to change something". A
  # `CHANGES_REQUESTED` PR with zero unresolved threads must not be routed to
  # rework; one with unresolved threads still is. This is the per-PR form for
  # callers that already hold the open-PR listing (e.g. `MergedTicketReconciler`).
  describe "open_pull_request_rework_verdict/2" do
    test "routes to rework when the open PR has unresolved review threads" do
      pr = %{"number" => 42, "head" => %{"sha" => "abc123"}}

      assert ReworkGate.open_pull_request_rework_verdict(pr,
               unresolved_threads_fetcher: fn _pr -> {:ok, [%{"id" => "thread-1"}]} end
             ) == {:ok, :rework}
    end

    test "refuses rework when every review thread is resolved (or none exist)" do
      pr = %{"number" => 42, "head" => %{"sha" => "abc123"}}

      assert ReworkGate.open_pull_request_rework_verdict(pr,
               unresolved_threads_fetcher: fn _pr -> {:ok, []} end
             ) == {:skip, :no_unresolved_review_threads}
    end

    test "refuses rework for a PR that is not a map" do
      assert ReworkGate.open_pull_request_rework_verdict(nil) == {:skip, :no_unresolved_review_threads}
    end

    test "surfaces a transient thread-read failure for the caller to retry or park" do
      pr = %{"number" => 42, "head" => %{"sha" => "abc123"}}

      assert ReworkGate.open_pull_request_rework_verdict(pr,
               unresolved_threads_fetcher: fn _pr -> {:error, :timeout} end
             ) == {:error, :timeout}
    end
  end

  # #2422: `rework` is only justified while a reviewer is actually asking for a
  # change, and the only signal that reliably answers that is unresolved review
  # threads — GitHub's `reviewDecision` never clears when findings are
  # addressed. A `CHANGES_REQUESTED` PR with zero unresolved threads must not
  # be routed to rework; one with unresolved threads still is. This is the
  # ticket-key form for callers that hold only the issue key (e.g. `CommentWake`).
  describe "verify_unresolved_review_threads/2" do
    test "allows rework when the open PR has unresolved review threads" do
      pr = %{"number" => 42, "head" => %{"sha" => "abc123"}}

      assert ReworkGate.verify_unresolved_review_threads("2422",
               open_pr_fetcher: fn _ -> {:ok, pr} end,
               unresolved_threads_fetcher: fn _pr -> {:ok, [%{"id" => "thread-1"}]} end
             ) == {:ok, pr}
    end

    test "refuses rework when every review thread is resolved (or none exist)" do
      pr = %{"number" => 42, "head" => %{"sha" => "abc123"}}

      assert ReworkGate.verify_unresolved_review_threads("2422",
               open_pr_fetcher: fn _ -> {:ok, pr} end,
               unresolved_threads_fetcher: fn _pr -> {:ok, []} end
             ) == {:skip, :no_unresolved_review_threads}
    end

    test "refuses rework when there is no open PR" do
      assert ReworkGate.verify_unresolved_review_threads("2422",
               open_pr_fetcher: fn _ -> {:ok, nil} end
             ) == {:skip, :no_open_pr}
    end

    test "surfaces a transient thread-read failure for the caller to retry or park" do
      pr = %{"number" => 42, "head" => %{"sha" => "abc123"}}

      assert ReworkGate.verify_unresolved_review_threads("2422",
               open_pr_fetcher: fn _ -> {:ok, pr} end,
               unresolved_threads_fetcher: fn _pr -> {:error, :timeout} end
             ) == {:error, :timeout}
    end
  end

  describe "head_sha/1" do
    test "reads the head commit SHA from the PR" do
      assert ReworkGate.head_sha(%{"head" => %{"sha" => "abc123"}}) == "abc123"
    end

    test "is nil when the PR carries no head SHA" do
      assert ReworkGate.head_sha(%{"number" => 42}) == nil
      assert ReworkGate.head_sha(nil) == nil
    end
  end

  # #2422: the same head SHA must not re-enter `agent:rework` more than N times;
  # exceeding the bound raises attention once and stops rather than looping. A
  # new head SHA starts a fresh count, so a genuine rework push is never bound.
  describe "verify_rework_attempt/4" do
    test "allows a rework write while the bound is not exhausted" do
      state = %State{rework_attempts: %{}}
      assert ReworkGate.verify_rework_attempt(state, "2422", "abc123") == {:ok, state}
    end

    test "allows a rework write for a new head SHA regardless of the old head's count" do
      state = %State{rework_attempts: %{{"2422", "oldhead"} => State.rework_attempt_limit()}}
      assert ReworkGate.verify_rework_attempt(state, "2422", "newhead") == {:ok, state}
    end

    test "refuses and raises attention once when the same head exceeds the bound" do
      state = %State{rework_attempts: %{{"2422", "abc123"} => State.rework_attempt_limit()}}
      parent = self()

      assert {:skip, :rework_attempt_limit_reached, next} =
               ReworkGate.verify_rework_attempt(state, "2422", "abc123",
                 emit_alert_fun: fn name, opts ->
                   send(parent, {:alert_emitted, name, opts})
                   :ok
                 end
               )

      assert_receive {:alert_emitted, "ticket.2422.agent.attention.rework_attempt_limit", opts}
      assert Keyword.get(opts, :needs_attention) == true
      assert MapSet.member?(next.rework_attempt_alerted, {"2422", "abc123"})
    end

    test "does not raise the attention a second time for the same head" do
      state = %State{
        rework_attempts: %{{"2422", "abc123"} => State.rework_attempt_limit()},
        rework_attempt_alerted: MapSet.new([{"2422", "abc123"}])
      }

      parent = self()

      assert {:skip, :rework_attempt_limit_reached, _next} =
               ReworkGate.verify_rework_attempt(state, "2422", "abc123",
                 emit_alert_fun: fn name, opts ->
                   send(parent, {:alert_emitted, name, opts})
                   :ok
                 end
               )

      refute_receive {:alert_emitted, _, _}
    end

    test "a nil head SHA fails open and never trips the bound" do
      state = %State{rework_attempts: %{}}
      assert ReworkGate.verify_rework_attempt(state, "2422", nil) == {:ok, state}
    end
  end
end
