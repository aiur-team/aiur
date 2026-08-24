defmodule Aiur.Orchestrator.ReworkGateTest do
  # `use Aiur.TestSupport` expands to `use ExUnit.Case` without `async: true`;
  # the availability tests inspect the tracker adapter, which reads global
  # config and cannot race async cases.
  use Aiur.TestSupport

  alias Aiur.Orchestrator.ReworkGate

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

  # #2422 / #2450: `rework` is only justified while a reviewer is actually
  # asking for a change, and the only signal that reliably answers that is
  # unresolved review threads — GitHub's `reviewDecision` never clears when
  # findings are addressed, so a `CHANGES_REQUESTED` verdict cannot distinguish
  # "outstanding findings" from "was once told to change something". A
  # `CHANGES_REQUESTED` PR with zero unresolved threads must not be routed to
  # rework; one with unresolved threads still is.
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
end
