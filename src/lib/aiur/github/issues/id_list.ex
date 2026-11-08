defmodule Aiur.GitHub.Issues.IdList do
  @moduledoc false

  alias Aiur.{GitHub, Issue}
  alias Aiur.GitHub.Access
  alias Aiur.GitHub.Issues.DispatchAuthorization
  import Aiur.GitHub.Issues.DispatchAuthorization, only: [authorize_dispatches: 6]
  import Aiur.GitHub.Issues.Normalize, only: [normalize_issue: 5]
  import Aiur.GitHub.Issues.Request, only: [conditional_get: 3, response_header: 2]
  import Aiur.GitHub.Issues.RawIssue, only: [confirmed_body: 2, put_issue_resource: 4, retain_validator: 3]

  @spec do_fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def do_fetch_issue_states_by_ids(issue_ids, opts) do
    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token() do
      prefix = GitHub.Config.label_prefix()
      request_fun = Keyword.get(opts, :request_fun, &Access.default_request_fun/1)

      with {:ok, issues} <-
             do_fetch_issues_by_id_list(issue_ids, request_fun, token, owner, repo, prefix) do
        {:ok, authorize_dispatches(issues, request_fun, token, owner, repo, prefix)}
      end
    end
  end

  @spec do_fetch_issue_states_by_ids_conditional([String.t()], map(), keyword()) ::
          {:ok, [Issue.t()], map()} | {:error, term()} | {:error, term(), map()}
  def do_fetch_issue_states_by_ids_conditional(issue_ids, cache, opts) do
    with {:ok, {owner, repo}} <- Access.parse_repo(),
         {:ok, token} <- Access.require_token() do
      ctx = %{
        request_fun: Keyword.get(opts, :request_fun, &Access.default_request_fun/1),
        token: token,
        owner: owner,
        repo: repo,
        prefix: GitHub.Config.label_prefix(),
        authorization_opts: Keyword.take(opts, [:allowed_users]),
        caller: "issue_by_id_conditional"
      }

      stable_ids = Enum.map(issue_ids, &to_string/1)
      cache = Map.take(cache, stable_ids)

      result =
        Enum.reduce_while(stable_ids, {:ok, [], cache}, &reduce_fetch_issue_conditional(ctx, &1, &2))

      case result do
        {:ok, issues, updated_cache} -> {:ok, Enum.reverse(issues), updated_cache}
        {:error, reason, updated_cache} -> {:error, reason, updated_cache}
      end
    end
  end

  @spec do_fetch_issues_by_id_list(
          [String.t()],
          function(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def do_fetch_issues_by_id_list(issue_ids, request_fun, token, owner, repo, prefix) do
    result =
      Enum.reduce_while(issue_ids, {:ok, []}, fn issue_id, {:ok, acc} ->
        url = "#{Access.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_id}"
        reduce_fetch_issue(request_fun, url, token, owner, repo, prefix, acc)
      end)

    case result do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  @spec reduce_fetch_issue(
          function(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          [Issue.t()]
        ) :: {:cont, {:ok, [Issue.t()]}} | {:halt, {:error, term()}}
  def reduce_fetch_issue(request_fun, url, token, owner, repo, prefix, acc) do
    case request_fun.(%{method: :get, url: url, token: token, caller: "issue_by_id"}) do
      {:ok, %{status: 200, body: body} = response} when is_map(body) ->
        revision = response_header(Map.get(response, :headers, []), "etag")
        {:cont, {:ok, [normalize_issue(body, owner, repo, prefix, revision) | acc]}}

      {:ok, %{status: 404}} ->
        {:cont, {:ok, acc}}

      {:ok, %{status: _status} = response} ->
        {:halt, {:error, Access.github_status_error(response)}}

      {:error, reason} ->
        {:halt, {:error, Access.classify_error({:error, reason})}}
    end
  end

  defp reduce_fetch_issue_conditional(ctx, issue_id, {:ok, issues, cache}) do
    fetch_conditional_issue(ctx, issue_id, issues, cache, false)
  end

  defp fetch_conditional_issue(ctx, issue_id, issues, cache, retried_without_cache?) do
    url = "#{Access.base_url()}/repos/#{ctx.owner}/#{ctx.repo}/issues/#{issue_id}"
    cached_entry = Map.get(cache, issue_id, %{})
    store_key = Access.key(:issue, ctx.owner, ctx.repo, issue_id)

    # The poll's own cache still wins when it has an entry, so the existing
    # behaviour is unchanged for the steady state. The store is consulted only
    # where the poll had nothing and would otherwise have spent a full read —
    # which is the case where some other reader of this same issue, typically the
    # Build Order page, has already paid for it.
    etag = Map.get(cached_entry, :etag) || store_validator(store_key, retried_without_cache?)

    case conditional_get(ctx, url, etag) do
      {:ok, body, retained_etag, _response} when is_map(body) ->
        # Publish the raw body, not the normalized `Issue`. Other readers of this
        # issue want different projections of it — the detail pane wants the
        # description and assignees the dispatch struct throws away — so the
        # shared entry has to be the response, with normalization left to each
        # reader.
        put_issue_resource(store_key, body, retained_etag, :poll)

        issue =
          body
          |> normalize_issue(ctx.owner, ctx.repo, ctx.prefix, retained_etag)
          |> DispatchAuthorization.authorize(
            ctx.request_fun,
            ctx.token,
            ctx.owner,
            ctx.repo,
            ctx.prefix,
            ctx.authorization_opts
          )

        entry = %{etag: retained_etag, issue: issue}
        {:cont, {:ok, [issue | issues], Map.put(cache, issue_id, entry)}}

      {:not_modified, retained_etag} ->
        materialize_not_modified_issue(ctx, issue_id, issues, cache, cached_entry, etag, retained_etag, retried_without_cache?)

      {:http_error, %{status: 404}} ->
        {:cont, {:ok, issues, Map.delete(cache, issue_id)}}

      {:http_error, response} ->
        {:halt, {:error, Access.github_status_error(response), cache}}

      {:error, reason} ->
        {:halt, {:error, reason, cache}}

      {:ok, _body, _retained_etag, response} ->
        {:halt, {:error, Access.github_status_error(response), cache}}
    end
  end

  defp materialize_not_modified_issue(ctx, issue_id, issues, cache, cached_entry, sent_etag, retained_etag, retried_without_cache?) do
    # Same reasoning as the detail path's `304`: the shared entry's freshness clock
    # has to move when GitHub says the body is still current, or the next reader
    # pays for bytes that were just proved unchanged.
    refresh_stored_issue(ctx, issue_id, sent_etag, retained_etag)

    case materialized_issue(ctx, issue_id, cached_entry, sent_etag, retained_etag) do
      %Issue{} = issue ->
        issue =
          DispatchAuthorization.authorize(
            issue,
            ctx.request_fun,
            ctx.token,
            ctx.owner,
            ctx.repo,
            ctx.prefix,
            ctx.authorization_opts
          )

        entry = %{etag: retained_etag, issue: issue}
        {:cont, {:ok, [issue | issues], Map.put(cache, issue_id, entry)}}

      _missing_materialized_issue when not retried_without_cache? ->
        fetch_conditional_issue(ctx, issue_id, issues, Map.delete(cache, issue_id), true)

      _missing_materialized_issue ->
        {:halt, {:error, :github_issue_not_modified_without_cached_value, cache}}
    end
  end

  defp refresh_stored_issue(ctx, issue_id, sent_etag, retained_etag) do
    ctx.owner
    |> then(&Access.key(:issue, &1, ctx.repo, issue_id))
    |> retain_validator(sent_etag, retained_etag)
  end

  # Only reached when the poll's own cache had no validator, so borrowing the
  # store's is never a downgrade: without it the request is unconditional.
  defp store_validator(_store_key, true), do: nil
  defp store_validator(store_key, false), do: Access.etag(store_key)

  # A `304` answered against a borrowed validator has no locally materialized
  # `Issue` to return, so normalize the shared body instead. Without this the
  # poll would fall through to a second, unconditional request for bytes the
  # store was already holding — the trap where sharing a validator without the
  # body makes things worse rather than better.
  defp materialized_issue(ctx, issue_id, cached_entry, sent_etag, retained_etag) do
    case Map.get(cached_entry, :issue) do
      %Issue{} = issue ->
        issue

      _missing ->
        store_key = Access.key(:issue, ctx.owner, ctx.repo, issue_id)

        case confirmed_body(store_key, sent_etag) do
          body when is_map(body) -> normalize_issue(body, ctx.owner, ctx.repo, ctx.prefix, retained_etag)
          _missing -> nil
        end
    end
  end
end
