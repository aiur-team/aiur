defmodule Aiur.CodeHost do
  @moduledoc "Adapter boundary for pull-request and review reads."

  alias Aiur.Tracker.NullCodeHost

  @spec available?() :: boolean()
  def available?, do: adapter() != NullCodeHost

  @spec adapter() :: module()
  def adapter do
    tracker = Aiur.Tracker.adapter()

    if Code.ensure_loaded?(tracker) and function_exported?(tracker, :code_host, 0),
      do: tracker.code_host() || NullCodeHost,
      else: NullCodeHost
  end

  @spec fetch_classified_pr_review_comments(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  def fetch_classified_pr_review_comments(value), do: adapter().fetch_classified_pr_review_comments(value)

  @spec fetch_classified_pr_reviews(String.t() | integer()) :: {:ok, [map()]} | {:error, term()}
  def fetch_classified_pr_reviews(value), do: adapter().fetch_classified_pr_reviews(value)

  @spec fetch_unaddressed_pr_review_thread_comments(String.t() | integer()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_unaddressed_pr_review_thread_comments(value), do: adapter().fetch_unaddressed_pr_review_thread_comments(value)

  @spec fetch_open_pull_request_for_branch(String.t() | integer()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_open_pull_request_for_branch(value), do: adapter().fetch_open_pull_request_for_branch(value)

  @spec fetch_open_pull_requests_for_branch(String.t() | integer()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_open_pull_requests_for_branch(value), do: adapter().fetch_open_pull_requests_for_branch(value)
  @spec optimistic_blocker(String.t() | integer(), integer() | nil) :: {:ok, map() | nil} | {:error, term()}
  def optimistic_blocker(value, number), do: optimistic_call(:optimistic_blocker, [value, number])

  @spec park_pull_request(String.t() | integer()) :: :ok | {:error, term()}
  def park_pull_request(value), do: optimistic_call(:park_pull_request, [value])

  @spec comment_optimistic_park(String.t() | integer(), String.t() | integer(), term()) :: :ok | {:error, term()}
  def comment_optimistic_park(dependent, blocker, cause), do: optimistic_call(:comment_optimistic_park, [dependent, blocker, cause])

  @spec withdraw_landing(integer()) :: {:ok, [atom()]} | {:error, term(), [atom()]} | {:error, term()}
  def withdraw_landing(number), do: optimistic_call(:withdraw_landing, [number])

  defp optimistic_call(function, arguments) do
    adapter = adapter()

    if function_exported?(adapter, function, length(arguments)),
      do: apply(adapter, function, arguments),
      else: {:error, :code_host_unavailable}
  end
end
