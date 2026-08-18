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
end
