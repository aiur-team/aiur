defmodule Aiur.Events.GithubWebhook.Deposit.CacheRetirement do
  @moduledoc """
  Retires the daemon read cache for the resources a delivery names.
  """

  alias Aiur.GitHub.ReadCache

  # A delivery is a fact about GitHub state that arrived for free, and the
  # `ReadCache` entries about the resources it touches are stale from that
  # moment — even when `ResourceStore` refuses the body, because the state
  # changed regardless of whether we could hold it. Retiring those entries is
  # what lets the `ReadCache` TTLs be measured in hours instead of seconds:
  # the delivery, not the clock, is the freshness mechanism. This is the same
  # primitive `write_through/3` already uses for Aiur's own writes, wired to
  # the second producer that knows about changes made outside this daemon.
  #
  # Deliberately runs even when the store is not running: a delivery proves the
  # change whether or not there is anywhere to hold its body.
  #
  # A `sub_issues` or `issue_dependencies` delivery changes only the Build Order
  # graph, which the catalog projects from the store (#2313) and whose GitHub
  # re-reads bypass `ReadCache`. It retires no numbered REST resource, so
  # invalidating here would fall through to `invalidate_repo/1` and clear the
  # whole repository's cache for a change that made nothing it serves stale —
  # paying a full re-fetch on the very path this ticket exists to stop charging.
  @spec invalidate_read_cache(String.t(), map(), String.t()) :: :ok
  def invalidate_read_cache(event_type, _payload, _repo)
      when event_type in ["sub_issues", "issue_dependencies"],
      do: :ok

  def invalidate_read_cache(event_type, payload, repo) do
    case delivery_numbers(event_type, payload) do
      [] -> ReadCache.invalidate_repo(repo)
      numbers -> Enum.each(numbers, &ReadCache.invalidate_number(repo, &1))
    end
  end

  # The numbers a delivery names, read from the payload rather than from the
  # `ResourceStore` keys written: a comment's store key is its comment id, which
  # is not a `ReadCache` identity. GitHub numbers issues and pull requests from
  # one sequence, so a delivery about either retires the single shared
  # `{:number, ...}` identity.
  #
  # Retiring goes through `ReadCache.invalidate_number/2`, which marks the
  # numbered issue-or-pull-request and, unconditionally, the repository's
  # collections. The collections marker goes on *every* delivery, not only on
  # actions that create or destroy a set member: a `labeled` delivery changes
  # what a `labels: [...]` enumeration answers, an edit changes what a ticket
  # list renders, a comment changes what a list of the repository's tickets
  # answers — and the `build_order_catalog` enumeration names no numbers, so
  # the collections identity is the only one that retires it.
  #
  # `check_run` and `check_suite` name their pull requests through the
  # `pull_requests` array; `pull_request_review_thread` through the pull request
  # it carries. Before #2372, all three fell through to "no nameable number"
  # and retired the *whole repository* on every delivery — and on a repo with
  # continuous CI activity that emptied the read cache faster than anything
  # could be served from it: 0% hits with a full, freshly-deposited table. They
  # now retire exactly the pull requests they name.
  #
  # A delivery with no nameable number (defensive; every handled event carries
  # one) answers `[]`, and `invalidate_read_cache/3` then falls back to retiring
  # the whole repository — the only thing known is that something in it changed,
  # and guessing which read is the failure mode this cache cannot afford.
  defp delivery_numbers(event_type, payload) do
    candidates =
      case event_type do
        "issue_comment" ->
          [get_in(payload, ["issue", "number"])]

        event when event in ["pull_request_review_comment", "pull_request_review", "pull_request"] ->
          [get_in(payload, ["pull_request", "number"])]

        "issues" ->
          [get_in(payload, ["issue", "number"])]

        event when event in ["check_run", "check_suite"] ->
          pull_request_numbers(get_in(payload, [event, "pull_requests"]))

        "pull_request_review_thread" ->
          [get_in(payload, ["pull_request", "number"])]

        _other ->
          []
      end

    candidates
    |> Enum.flat_map(fn number ->
      case parse_number(number) do
        parsed when is_integer(parsed) -> [parsed]
        _unusable -> []
      end
    end)
    |> Enum.uniq()
  end

  defp pull_request_numbers(nil), do: []

  defp pull_request_numbers(pull_requests) when is_list(pull_requests) do
    # A malformed element (not a map) must not raise here: `deposit/3`'s rescue
    # would swallow the whole `invalidate_read_cache/3` call and leave the cache
    # stale rather than over-retired. Skip the element and still retire the
    # pull requests the rest of the array names.
    Enum.flat_map(pull_requests, fn
      pr when is_map(pr) -> [get_in(pr, ["number"])]
      _not_a_map -> []
    end)
  end

  defp pull_request_numbers(_other), do: []

  defp parse_number(number) when is_integer(number) and number > 0, do: number

  defp parse_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> nil
    end
  end

  defp parse_number(_number), do: nil
end
