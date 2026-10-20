defmodule Aiur.GitHub.TrackerPollCycleTest do
  use Aiur.TestSupport, async: false

  alias Aiur.GitHub.AuthPreflight
  alias Aiur.GitHub.CycleFetchCache
  alias Aiur.Tracker

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "example/repo")
    on_exit(fn -> CycleFetchCache.end_cycle() end)
    :ok
  end

  test "poll cycles reuse reads and discard cached results when they finish" do
    fetch = fn -> {:ok, make_ref()} end

    first =
      Tracker.with_poll_cycle(fn ->
        result = CycleFetchCache.fetch(:key, fetch)
        assert CycleFetchCache.fetch(:key, fn -> flunk("cached within cycle") end) == result
        result
      end)

    refute CycleFetchCache.fetch(:key, fetch) == first
    refute Tracker.with_poll_cycle(fn -> CycleFetchCache.fetch(:key, fetch) end) == first
  end

  test "poll cycle cleanup runs when its operation raises" do
    fetch = fn -> {:ok, make_ref()} end

    assert_raise RuntimeError, "dispatch failed", fn ->
      Tracker.with_poll_cycle(fn ->
        send(self(), {:cached_result, CycleFetchCache.fetch(:key, fetch)})
        raise "dispatch failed"
      end)
    end

    assert_received {:cached_result, previous}
    refute CycleFetchCache.fetch(:key, fetch) == previous
  end

  test "GitHub preflight formatting preserves its diagnostic" do
    reason = {:github_auth_preflight_failed, %{reason: :bad_credentials, repo: "example/repo"}}
    assert Tracker.format_preflight_error(reason) == AuthPreflight.format_auth_preflight_error(reason)
  end
end
