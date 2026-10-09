defmodule Aiur.Tracker.NullCodeHost do
  @moduledoc "Empty PR evidence for trackers without a code host."
  @behaviour Aiur.Tracker.CodeHost

  @impl Aiur.Tracker.CodeHost
  def fetch_classified_pr_review_comments(_value), do: {:ok, []}

  @impl Aiur.Tracker.CodeHost
  def fetch_classified_pr_reviews(_value), do: {:ok, []}

  @impl Aiur.Tracker.CodeHost
  def fetch_unaddressed_pr_review_thread_comments(_value), do: {:ok, []}

  @impl Aiur.Tracker.CodeHost
  def fetch_open_pull_request_for_branch(_value), do: {:ok, nil}

  @impl Aiur.Tracker.CodeHost
  def fetch_open_pull_requests_for_branch(_value), do: {:ok, []}
end
