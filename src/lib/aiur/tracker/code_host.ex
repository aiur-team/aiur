defmodule Aiur.Tracker.CodeHost do
  @moduledoc "Pull-request and review reads provided by a code host."

  @callback fetch_classified_pr_review_comments(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_classified_pr_reviews(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_unaddressed_pr_review_thread_comments(String.t() | integer()) ::
              {:ok, [map()]} | {:error, term()}
  @callback fetch_open_pull_request_for_branch(String.t() | integer()) ::
              {:ok, map() | nil} | {:error, term()}
  @callback fetch_open_pull_requests_for_branch(String.t() | integer()) ::
              {:ok, [map()]} | {:error, term()}
end
