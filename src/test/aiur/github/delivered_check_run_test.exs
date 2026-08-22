defmodule Aiur.GitHub.DeliveredCheckRunTest do
  @moduledoc """
  The CI poll pipe's read side of the store (#2310).

  `CIPollBatch`'s own tests assert the effect — a document with a displaced
  target's aliases removed. These assert the decision itself, one refusal at a
  time, so a future change that widens any of them has to say so. Every refusal
  is a fetch: this is the fail-toward-polling rule the #2276 false-`:passed`
  failure exists to enforce.
  """

  use Aiur.TestSupport

  alias Aiur.GitHub.{DeliveredCheckRun, ResourceStore}

  @repo "owner/repo"

  setup do
    ResourceStore.reset()
    on_exit(&ResourceStore.reset/0)
    :ok
  end

  defp assert_matches(entry) do
    assert entry.key == ResourceStore.key_for_repo(:check_run, @repo, "42")
    assert entry.check_run == check_run()
    assert entry.marker == "2026-08-22T12:05:00Z"
    assert entry.head_sha == "abc123"
  end

  test "answers a delivery on the head the last poll observed, for a run it saw" do
    put(42, check_run(), :webhook, "2026-08-22T12:05:00Z")

    assert {:ok, entry} =
             DeliveredCheckRun.signal_for_target("42", "owner", "repo",
               ci_heads_by_target: %{"42" => "abc123"},
               ci_check_run_ids_by_target: %{"42" => [5501]}
             )

    assert_matches(entry)
    assert %{"id" => 5501, "head_sha" => "abc123"} = entry.check_run
  end

  test "owner and repo casing cannot hide the delivered entry from the poller" do
    put(42, check_run(), :webhook, "2026-08-22T12:05:00Z")

    assert {:ok, _entry} =
             DeliveredCheckRun.signal_for_target("42", "Owner", "Repo",
               ci_heads_by_target: %{"42" => "abc123"},
               ci_check_run_ids_by_target: %{"42" => [5501]}
             )
  end

  # `:data_source` distinguishes a delivered body from a polled one; a poll is
  # not free, so a body the poll wrote must not displace another poll.
  test "refuses a body that was not delivered" do
    put(42, check_run(), :poll, "2026-08-22T12:05:00Z")

    assert DeliveredCheckRun.signal_for_target("42", "owner", "repo",
             ci_heads_by_target: %{"42" => "abc123"},
             ci_check_run_ids_by_target: %{"42" => [5501]}
           ) == :miss
  end

  # The freshness bound is on `fetched_at_ms`, the age of the body, never on
  # `recorded_at_ms`, which every write touches.
  test "refuses a body older than the freshness bound" do
    put(42, check_run(), :webhook, "2026-08-22T12:05:00Z")

    assert DeliveredCheckRun.signal_for_target("42", "owner", "repo",
             delivered_check_run_max_age_ms: 0,
             ci_heads_by_target: %{"42" => "abc123"},
             ci_check_run_ids_by_target: %{"42" => [5501]}
           ) == :miss
  end

  # "Has this been deposited since I last read it?": the poll that serves a
  # delivery marks it processed at its marker, so the *next* cycle fetches and
  # re-establishes the full rollup — the safety net a dropped delivery relies
  # on. Without this, one delivery would skip every poll until it aged out.
  test "a delivery already served by a poll no longer answers" do
    put(42, check_run(), :webhook, "2026-08-22T12:05:00Z")

    assert {:ok, entry} =
             DeliveredCheckRun.signal_for_target("42", "owner", "repo",
               ci_heads_by_target: %{"42" => "abc123"},
               ci_check_run_ids_by_target: %{"42" => [5501]}
             )

    assert :ok = DeliveredCheckRun.mark_served(entry)

    assert DeliveredCheckRun.signal_for_target("42", "owner", "repo",
             ci_heads_by_target: %{"42" => "abc123"},
             ci_check_run_ids_by_target: %{"42" => [5501]}
           ) == :miss
  end

  # A delivery whose marker moved (a completion, a re-run, a new run) is a new
  # fact and answers again even after a prior marker was served.
  test "a delivery with a newer marker answers again after a prior one was served" do
    put(42, check_run(5501, "queued", nil, "2026-08-22T12:05:00Z"), :webhook, "2026-08-22T12:05:00Z")

    assert {:ok, entry} =
             DeliveredCheckRun.signal_for_target("42", "owner", "repo",
               ci_heads_by_target: %{"42" => "abc123"},
               ci_check_run_ids_by_target: %{"42" => [5501]}
             )

    assert :ok = DeliveredCheckRun.mark_served(entry)

    put(42, check_run(5501, "completed", "success", "2026-08-22T12:10:00Z"), :webhook, "2026-08-22T12:10:00Z")

    assert {:ok, %{marker: "2026-08-22T12:10:00Z"}} =
             DeliveredCheckRun.signal_for_target("42", "owner", "repo",
               ci_heads_by_target: %{"42" => "abc123"},
               ci_check_run_ids_by_target: %{"42" => [5501]}
             )
  end

  # A run registered after the baseline is the #2276 failure: answering it
  # would let the poller call a queued required check passed. It must fetch.
  test "refuses a check run the last poll never saw" do
    put(42, check_run(5502), :webhook, "2026-08-22T12:05:00Z")

    assert DeliveredCheckRun.signal_for_target("42", "owner", "repo",
             ci_heads_by_target: %{"42" => "abc123"},
             ci_check_run_ids_by_target: %{"42" => [5501]}
           ) == :miss
  end

  # A delivery on a head the last poll did not observe cannot answer the
  # question the poll is about to ask; the poll fetches.
  test "refuses a delivery on a head the last poll did not observe" do
    put(42, check_run(), :webhook, "2026-08-22T12:05:00Z")

    assert DeliveredCheckRun.signal_for_target("42", "owner", "repo",
             ci_heads_by_target: %{"42" => "deadbeef"},
             ci_check_run_ids_by_target: %{"42" => [5501]}
           ) == :miss
  end

  test "a target with no prior observation matches neither head nor id and fetches" do
    put(42, check_run(), :webhook, "2026-08-22T12:05:00Z")

    assert DeliveredCheckRun.signal_for_target("42", "owner", "repo") == :miss
  end

  test "answers :miss for a ticket no delivery has named" do
    assert DeliveredCheckRun.signal_for_target("42", "owner", "repo") == :miss
  end

  defp put(target, body, source, marker) do
    :check_run
    |> ResourceStore.key_for_repo(@repo, target)
    |> ResourceStore.put_resource(body, source: source, version: marker)
  end

  defp check_run(id \\ 5501, status \\ "completed", conclusion \\ "success", completed_at \\ "2026-08-22T12:05:00Z") do
    %{
      "id" => id,
      "name" => "test",
      "head_sha" => "abc123",
      "status" => status,
      "conclusion" => conclusion,
      "started_at" => "2026-08-22T11:55:00Z",
      "completed_at" => completed_at
    }
  end
end
