defmodule Aiur.GitHub.Issues.RawIssue do
  @moduledoc false

  alias Aiur.Bounded
  alias Aiur.GitHub.Access
  alias Aiur.GitHub.Issues.Request

  @spec fetch_issue_raw_conditional(integer() | String.t(), keyword()) :: {:ok, map(), :fresh | :not_modified | :fetched} | {:error, term()}
  def fetch_issue_raw_conditional(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- raw_repository(opts),
         {:ok, token} <- Access.require_token(opts) do
      key = Access.key(:issue, owner, repo, to_string(issue_number))

      case stored_issue(key, opts) do
        body when is_map(body) ->
          {:ok, body, :fresh}

        nil ->
          revalidate_raw_issue(issue_number, owner, repo, token, key, opts, false)
      end
    end
  end

  # An explicit revalidation deliberately ignores a held body: the caller is
  # asking to be *sure*, and the conditional request that answers that is free
  # when nothing changed.
  defp stored_issue(key, opts) do
    if Keyword.get(opts, :revalidate, false) or Keyword.get(opts, :unconditional, false) do
      nil
    else
      servable_within(Access.fetch_resource(key), Keyword.get(opts, :freshness_ms))
    end
  end

  # The store hands back when the body was recorded; the caller says how old it
  # will accept. Comparing them here — rather than trusting whichever number the
  # store happens to prefer — is what lets two readers of the same issue with
  # different tolerances share one entry without either being served something it
  # said it could not use.
  defp servable_within({:ok, %{data: body, fetched_at_ms: fetched_at_ms}}, freshness_ms)
       when is_map(body) and is_integer(fetched_at_ms) and is_integer(freshness_ms) and freshness_ms > 0 do
    if System.system_time(:millisecond) - fetched_at_ms <= freshness_ms, do: body, else: nil
  end

  defp servable_within(_answer, _freshness_ms), do: nil

  defp revalidate_raw_issue(issue_number, owner, repo, token, key, opts, retried_without_validator?) do
    request_fun = Keyword.get(opts, :request_fun, &Access.default_request_fun/1)
    url = "#{Access.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_number}"
    etag = if retried_without_validator? or Keyword.get(opts, :unconditional, false), do: nil, else: Access.etag(key)

    request = %{method: :get, url: url, token: token, max_response_bytes: Request.max_issue_response_bytes(), caller: Keyword.get(opts, :caller, "issue_raw_conditional")}
    request = if is_binary(etag) and etag != "", do: Map.put(request, :etag, etag), else: request

    context = %{
      issue_number: issue_number,
      owner: owner,
      repo: repo,
      token: token,
      key: key,
      opts: opts,
      etag: etag,
      retried_without_validator?: retried_without_validator?
    }

    request |> request_fun.() |> handle_raw_issue_response(context)
  end

  defp handle_raw_issue_response({:ok, %{private: %{aiur_response_too_large: true}, status: status} = response}, _context)
       when status != 200 do
    {:error, Access.github_status_error(response)}
  end

  defp handle_raw_issue_response({:ok, %{private: %{aiur_response_too_large: true}}}, _context) do
    {:error, :github_issue_response_too_large}
  end

  defp handle_raw_issue_response({:ok, %{status: 200, body: body} = response}, context) when is_map(body) do
    retained = Access.header(Map.get(response, :headers, []), "etag") || context.etag

    put_issue_resource(context.key, body, retained, :fetch)
    {:ok, body, :fetched}
  end

  defp handle_raw_issue_response({:ok, %{status: 200}}, _context), do: {:error, :invalid_github_issue_response}

  defp handle_raw_issue_response({:ok, %{status: 304} = response}, context) do
    serve_not_modified_raw_issue(context, Access.header(Map.get(response, :headers, []), "etag") || context.etag)
  end

  defp handle_raw_issue_response({:ok, %{status: _status} = response}, _context) do
    {:error, Access.github_status_error(response)}
  end

  defp handle_raw_issue_response({:error, reason}, _context), do: {:error, Access.classify_error({:error, reason})}

  # A `304` proves the stored body is still current, which is only useful if the
  # body is still there. When it is not — a restart dropped it, or the store's
  # own bound evicted it — re-asking without the validator is the correct
  # recovery and costs one ordinary request. Reporting an error instead would turn
  # a cache miss into a page failure.
  #
  # `304` is answered from the held body regardless of the caller's freshness
  # window: GitHub has just certified that the body is current, so its age is no
  # longer evidence of anything.
  #
  # It certifies only the body the sent validator sat beside. A body deposited
  # while the request was in flight — a Build Order reconciliation files one with
  # `"labels" => []` — is re-read rather than served as GitHub's (#5180).
  defp serve_not_modified_raw_issue(context, retained_etag) do
    case confirmed_body(context.key, context.etag) do
      body when is_map(body) ->
        # A `304` may rotate the validator, and the new one is what the next
        # conditional request has to send. Retaining it is the only write this
        # path makes — see `retain_validator/3` for why the body is left alone.
        retain_validator(context.key, context.etag, retained_etag)
        {:ok, body, :not_modified}

      _missing when not context.retried_without_validator? ->
        if Access.data(context.key) == nil, do: Access.drop_data(context.key)
        revalidate_raw_issue(context.issue_number, context.owner, context.repo, context.token, context.key, context.opts, true)

      _missing ->
        {:error, :github_issue_not_modified_without_cached_value}
    end
  end

  @spec confirmed_body(term(), term()) :: map() | nil
  def confirmed_body(key, sent_etag) do
    case Access.fetch_resource(key) do
      {:ok, %{data: body, etag: ^sent_etag}} when is_map(body) and is_binary(sent_etag) -> body
      _unconfirmed -> nil
    end
  end

  # One deposit shape for both readers of this endpoint, so the poll path and the
  # detail path cannot disagree about what an issue entry contains.
  #
  # `:version` is the issue's own `updated_at`. It is what lets a later webhook
  # delivery for the same issue tell "this is the change I already hold" from
  # "this is a newer one".
  #
  # It does *not* follow that re-depositing an unchanged issue is silent: the
  # store's change test includes `:source`, and these two readers deposit under
  # different sources, so alternating readers of an unchanged issue do publish.
  # `Aiur.BuildOrder.GraphProjection` subscribes to `:issue`, and such a publish
  # rebuilds its catalog from the store. That rebuild is a store read, not a
  # GitHub read, and it buys no graph read unless a member's lifecycle actually
  # moved (#2608). The honest fix belongs in the store's change test rather than
  # here, so this is named rather than worked around.
  #
  # `:processed` is deliberately never passed: fetching an issue is not the same
  # as having acted on it, and marking it handled here would suppress the wake
  # that the resource's genuine change is supposed to cause.
  @spec put_issue_resource(term(), map(), term(), atom()) :: term()
  def put_issue_resource(key, body, etag, source) do
    Access.deposit_unless_older(key, body, source: source, version: issue_version(body), etag: etag)
  end

  # What a `304` is allowed to write back, and — more importantly — what it is not.
  #
  # It is tempting to re-deposit the validated body so the entry's `fetched_at_ms`
  # moves and the next reader inside its window is served for nothing. That was
  # tried and is wrong, and the reason is worth keeping: the body is read, then
  # written, and a webhook delivery landing between the two makes the write
  # incoherent. `put_resource/3` and `update_resource/3` both take the version as
  # a fixed option while the body comes from the entry, so whichever one wins,
  # the pair can disagree — a body carrying one `updated_at` filed under another.
  # A concurrency test caught exactly that (`shared_resource_store_test.exs`), and
  # an entry whose body and version describe different objects is worse than a
  # stale clock: every later version comparison is then made against a marker that
  # never belonged to the body it is attached to.
  #
  # So the clock does not move, and the only thing written back is the validator,
  # through the store's own narrow `put_etag/3`. What that costs is one extra
  # conditional request the next time a reader's window has passed — and a
  # conditional request that answers `304` costs **no primary rate limit**, which
  # is the whole reason this path exists. The optimisation was saving a free
  # request at the price of a corruptible entry.
  #
  # The validator is written only while the store still holds the one that was
  # sent. The poll sends its own cached ETag, so its `304` vouches for the poll's
  # body, not for whatever the store holds now; stamping it onto a labelless
  # reconciliation body made every later guarded read see no state (#5180).
  @spec retain_validator(term(), term(), term()) :: term()
  def retain_validator(key, sent_etag, etag), do: Access.put_etag(key, etag, sent_etag)

  # Both call sites have already matched `body` as a map, so there is deliberately
  # no non-map clause: dialyzer proves it unreachable.
  defp issue_version(body) when is_map(body) do
    case Map.get(body, "updated_at") do
      version when is_binary(version) and version != "" -> version
      _absent -> nil
    end
  end

  # A validator is only worth sending alongside the body it validates.
  #
  defp raw_repository(opts) do
    case Keyword.fetch(opts, :repository) do
      {:ok, {owner, repo}} ->
        repository_components(owner, repo)

      {:ok, _invalid_repository} ->
        {:error, :invalid_github_repository}

      :error ->
        with {:ok, {owner, repo}} <- Access.parse_repo() do
          repository_components(owner, repo)
        end
    end
  end

  defp repository_components(owner, repo) do
    case Bounded.github_repository_components(owner, repo) do
      {:ok, repository} -> {:ok, repository}
      :error -> {:error, :invalid_github_repository}
    end
  end
end
