defmodule Aiur.Tracker.CodeHost do
  @moduledoc "Pull-request and review reads provided by a code host."

  @callback ci_readiness() :: module() | nil
  @optional_callbacks ci_readiness: 0

  @callback fetch_classified_pr_review_comments(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_classified_pr_reviews(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_unaddressed_pr_review_thread_comments(String.t() | integer()) ::
              {:ok, [map()]} | {:error, term()}
  @callback fetch_open_pull_request_for_branch(String.t() | integer()) ::
              {:ok, map() | nil} | {:error, term()}
  @callback fetch_open_pull_requests_for_branch(String.t() | integer()) ::
              {:ok, [map()]} | {:error, term()}
  @callback optimistic_blocker(String.t() | integer(), integer() | nil) :: {:ok, map() | nil} | {:error, term()}
  @callback optimistic_blocker(String.t() | integer(), integer() | nil, keyword()) :: {:ok, map() | nil} | {:error, term()}
  @callback park_pull_request(String.t() | integer()) :: :ok | {:error, term()}
  @callback comment_optimistic_park(String.t() | integer(), String.t() | integer(), term()) :: :ok | {:error, term()}
  @callback withdraw_landing(integer()) :: {:ok, [atom()]} | {:error, term(), [atom()]}
  @callback pull_request_body_edited_at(integer()) :: {:ok, String.t() | nil} | {:error, term()}
  @optional_callbacks optimistic_blocker: 2, optimistic_blocker: 3, park_pull_request: 1, comment_optimistic_park: 3, withdraw_landing: 1, pull_request_body_edited_at: 1
end
