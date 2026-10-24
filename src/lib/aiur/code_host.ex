defmodule Aiur.CodeHost do
  @moduledoc "Adapter boundary for pull-request and review reads."

  alias Aiur.Tracker.NullCodeHost

  @spec ci_readiness() :: module() | nil
  def ci_readiness, do: readiness_provider(adapter())

  @doc false
  @spec ci_readiness(String.t() | nil) :: module() | nil
  def ci_readiness(kind) do
    tracker = Aiur.Tracker.Registry.adapter_for(kind)
    if Code.ensure_loaded?(tracker) and function_exported?(tracker, :code_host, 0), do: readiness_provider(tracker.code_host())
  end

  defp readiness_provider(adapter) do
    if adapter && Code.ensure_loaded?(adapter) && function_exported?(adapter, :ci_readiness, 0), do: adapter.ci_readiness()
  end

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

  @spec optimistic_blocker(String.t() | integer(), integer() | nil, keyword()) :: {:ok, map() | nil} | {:error, term()}
  def optimistic_blocker(value, number, opts) do
    adapter = adapter()

    cond do
      function_exported?(adapter, :optimistic_blocker, 3) -> adapter.optimistic_blocker(value, number, opts)
      function_exported?(adapter, :optimistic_blocker, 2) -> adapter.optimistic_blocker(value, number)
      true -> {:error, :code_host_unavailable}
    end
  end

  @spec park_pull_request(String.t() | integer()) :: :ok | {:error, term()}
  def park_pull_request(value), do: optimistic_call(:park_pull_request, [value])

  @spec comment_optimistic_park(String.t() | integer(), String.t() | integer(), term()) :: :ok | {:error, term()}
  def comment_optimistic_park(dependent, blocker, cause), do: optimistic_call(:comment_optimistic_park, [dependent, blocker, cause])

  @spec withdraw_landing(integer()) :: {:ok, [atom()]} | {:error, term(), [atom()]} | {:error, term()}
  def withdraw_landing(number), do: optimistic_call(:withdraw_landing, [number])

  @spec pull_request_body_edited_at(integer()) :: {:ok, String.t() | nil} | {:error, term()}
  def pull_request_body_edited_at(number), do: optimistic_call(:pull_request_body_edited_at, [number])

  @spec update_pull_request_body(integer(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_pull_request_body(number, body), do: optimistic_call(:update_pull_request_body, [number, body])

  defp optimistic_call(function, arguments) do
    adapter = adapter()

    if function_exported?(adapter, function, length(arguments)),
      do: apply(adapter, function, arguments),
      else: {:error, :code_host_unavailable}
  end
end
