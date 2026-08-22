defmodule Aiur.GitHub.DeliveredPullRequestTest do
  @moduledoc """
  The poll pipe's read side of the store (#2265).

  The batches' own tests assert the *effect* — a document with the speculative
  discovery aliases removed. These assert the decision itself, one refusal at a
  time, so a future change that widens any of them has to say so.
  """

  use Aiur.TestSupport

  alias Aiur.GitHub.{DeliveredPullRequest, ResourceStore}

  @repo "owner/repo"

  setup do
    ResourceStore.reset()
    on_exit(&ResourceStore.reset/0)
    :ok
  end

  test "answers the number a delivery recorded for the ticket" do
    put(42, %{"number" => 77, "state" => "open"}, :webhook)

    assert DeliveredPullRequest.number_for_target("42", "owner", "repo") == 77
  end

  test "owner and repo casing cannot hide the delivered entry from the poller" do
    put(42, %{"number" => 77, "state" => "open"}, :webhook)

    assert DeliveredPullRequest.number_for_target("42", "Owner", "Repo") == 77
  end

  # `:data_source` already distinguished a delivered body from a fetched one;
  # this is the reader that finally uses it. A body some reader's own fetch
  # deposited is not wrong, but it is not free, and restricting to deliveries
  # keeps the saving attributable to the pipe that produced it.
  test "refuses a body that was not delivered" do
    put(42, %{"number" => 77, "state" => "open"}, :fetch)

    assert DeliveredPullRequest.number_for_target("42", "owner", "repo") == nil
  end

  # A ticket's second pull request can only exist once the first closed, and the
  # `pull_request` delivery for that close overwrites this very entry — so the
  # entry that would send a poller to a superseded number is the entry this
  # refuses.
  test "refuses a delivered pull request that is no longer open" do
    put(42, %{"number" => 77, "state" => "closed"}, :webhook)

    assert DeliveredPullRequest.number_for_target("42", "owner", "repo") == nil
  end

  test "refuses a body with no usable number" do
    put(42, %{"state" => "open"}, :webhook)
    put(43, %{"number" => "77", "state" => "open"}, :webhook)

    assert DeliveredPullRequest.number_for_target("42", "owner", "repo") == nil
    assert DeliveredPullRequest.number_for_target("43", "owner", "repo") == nil
  end

  test "answers nil for a ticket no delivery has named" do
    assert DeliveredPullRequest.number_for_target("42", "owner", "repo") == nil
  end

  # The freshness bound is on `fetched_at_ms`, the age of the *body*, never on
  # `recorded_at_ms`, which every write touches including a bodyless
  # processed-mark — the confusion #2174 is fixing in the eviction sweep.
  test "refuses a body older than the freshness bound" do
    put(42, %{"number" => 77, "state" => "open"}, :webhook)

    assert DeliveredPullRequest.number_for_target("42", "owner", "repo", delivered_identity_max_age_ms: 0) == nil
    assert DeliveredPullRequest.number_for_target("42", "owner", "repo") == 77
  end

  test "a caller can opt out entirely without unwiring the module" do
    put(42, %{"number" => 77, "state" => "open"}, :webhook)

    assert DeliveredPullRequest.number_for_target("42", "owner", "repo", delivered_identity: false) == nil
  end

  test "an unusable identity answers nil rather than raising in a poller" do
    assert DeliveredPullRequest.number_for_target(nil, "owner", "repo") == nil
    assert DeliveredPullRequest.number_for_target("42", "owner", nil) == nil
  end

  defp put(target, body, source) do
    :branch_pull_request
    |> ResourceStore.key_for_repo(@repo, target)
    |> ResourceStore.put_resource(body, source: source, version: "2026-08-20T00:00:00Z")
  end
end
