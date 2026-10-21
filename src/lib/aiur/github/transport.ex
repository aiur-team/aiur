defmodule Aiur.GitHub.Transport do
  @moduledoc """
  Shared GitHub REST and GraphQL transport helpers.

  Every HTTP request is executed on a short-lived worker process, never on the
  calling process. The Orchestrator was captured blocked in `:gen.do_call/4`
  inside `Mint.Core.Transport.SSL.recv/3` with 6,000+ messages queued behind it
  while `run_queue` was 0 — one process holding a socket, not a busy host
  (#1837). A GenServer that owns a socket cannot serve anything else while the
  peer is slow, and `receive_timeout` alone does not bound that: Req retries, so
  a single logical read can hold the caller for minutes.

  Moving the socket to a worker means the caller waits on a message it can
  abandon. On deadline the worker is killed, which closes the socket with it,
  and the caller gets `{:error, {:aiur, :unknown, :fetch_deadline_exceeded}}` instead of wedging.
  Quota preflight/observe stay on the caller so accounting order is unchanged.
  Local budget admission has its own bound (5 s; 1.5 s on the Orchestrator, whose
  waits sleep on it) and completes before the HTTP deadline starts, so broker
  startup and SQLite work cannot consume the time reserved for the network request.

  What this does *not* do: it does not stop a GenServer blocking on a GitHub
  read. The caller still waits in a selective receive for the reply, so the
  Orchestrator's mailbox still grows while its poll cycle fetches. What changes
  is that the wait is bounded and the socket is not the caller's to leak — see
  `request_deadline_ms/1` for the two bounds and why the Orchestrator gets the
  tighter one.
  """

  alias Aiur.GitHub.Access.{Settings, Token}
  alias Aiur.GitHub.AuthPreflight
  alias Aiur.GitHub.Budget
  alias Aiur.GitHub.CredentialHeadroom
  alias Aiur.GitHub.Errors
  alias Aiur.GitHub.{GraphQLErrors, HoldPressure}
  alias Aiur.GitHub.{Quota, Transport.TestScope}
  alias Aiur.GitHub.ReadCache
  alias Aiur.GitHub.Transport.{GraphQL, OffProcess}

  require Logger

  @default_request_timeout_ms 30_000
  @default_request_deadline_ms 60_000
  @deadline_margin_ms 5_000
  @orchestrator_request_deadline_ms 10_000
  @budget_admission_timeout_ms 5_000

  @spec base_url() :: String.t()
  def base_url, do: Settings.current().api_base_url

  @spec graphql_url() :: String.t()
  def graphql_url, do: Settings.current().graphql_url

  @spec parse_repo() :: {:ok, {String.t(), String.t()}} | {:error, term()}
  def parse_repo do
    case Settings.current().repo do
      nil ->
        {:error, :missing_github_repo}

      repo_string ->
        case String.split(repo_string, "/") do
          [owner, repo] -> {:ok, {owner, repo}}
          _ -> {:error, {:invalid_github_repo, repo_string}}
        end
    end
  end

  @spec require_token() :: {:ok, String.t()} | {:error, :missing_github_token}
  def require_token do
    case Token.token() do
      nil -> {:error, :missing_github_token}
      token -> {:ok, token}
    end
  end

  @spec require_token(keyword()) :: {:ok, String.t()} | {:error, :missing_github_token}
  def require_token(opts) do
    case Keyword.get(opts, :token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        require_token()
    end
  end

  @doc """
  Executes one GitHub request.

  The credential is chosen here rather than where the request was built, because
  this is the last point that knows the URL (which budget it spends) and the
  method/body (whether it writes) at the same time. With a single credential
  configured — the default — `assign/2` returns the request untouched and this
  is the same code path it always was.

  Selection happens **outside** `quota_request/2`, so it precedes the read
  cache. That ordering is deliberate. `ReadCache` keys entries on the request's
  shape and its identities, never on who authenticated, so a hit is served
  whichever credential the selector picked — which is correct only because a hit
  spends nothing: no budget is charged, so no budget can be charged to the wrong
  credential. Selecting after the cache would invert that, letting a miss be
  fetched before anything had decided who should pay for it.

  Sharing one credential's answer with another is the same trade `Aiur.GitHub.AgentCache`
  already makes between agents, which run under different credentials again. It
  holds while every pooled credential can read the same repository; a pool whose
  members had different visibility would need the credential in the cache key.
  """
  @spec default_request_fun(map()) :: {:ok, map()} | {:error, term()}
  def default_request_fun(req), do: TestScope.run(req, &do_request/1)

  defp do_request(%{method: :get, url: url, token: token} = req) do
    headers =
      case Map.get(req, :etag) do
        nil -> github_headers(token, req)
        etag -> [{"If-None-Match", etag} | github_headers(token, req)]
      end

    quota_request(req, fn -> Req.get(url, request_options(headers, req)) end)
  end

  defp do_request(%{method: :post, url: url, token: token, body: body} = req) do
    options =
      token
      |> github_headers(req)
      |> request_options(req)
      |> Keyword.put(:json, body)

    quota_request(req, fn -> Req.post(url, options) end)
  end

  defp do_request(%{method: :patch, url: url, token: token, body: body} = req) do
    quota_request(req, fn ->
      options = github_headers(token, req) |> request_options(req) |> Keyword.put(:json, body)
      Req.patch(url, options)
    end)
  end

  defp do_request(%{method: :delete, url: url, token: token} = req) do
    quota_request(req, fn -> Req.delete(url, request_options(github_headers(token, req), req)) end)
  end

  # The cache wraps quota, not the other way round. A read the cache answers
  # never reaches preflight, admission or the socket, which is the entire saving:
  # a request that is priced and then not sent has cost the budget nothing, but a
  # request that is sent and then discarded has cost it everything.
  #
  # `ReadCache.through/2` is also where a *write* retires what it changed, so a
  # mutation cannot leave a stale read behind it. Both halves live at this one
  # call because a read that could be added without passing through here is a
  # read nobody can account for — the same argument `GraphQLCost` makes for
  # pricing at the chokepoint.
  defp quota_request(request, request_fun) do
    ReadCache.through(request, fn -> uncached_quota_request(request, request_fun) end)
  end

  defp uncached_quota_request(request, request_fun) do
    quota = Application.get_env(:aiur, :github_quota_server, Quota)

    case quota_preflight(quota, request) do
      :ok ->
        deadline_ms = request_deadline_ms(request)
        budget_request(quota, request, request_fun, deadline_ms)

      {:hold, hold} ->
        {:error, {:aiur, :locally_held, HoldPressure.record(hold)}}
    end
  end

  defp budget_request(quota, request, request_fun, deadline_ms) do
    admission_ms = min(deadline_ms, if(orchestrator_process?(), do: 1_500, else: @budget_admission_timeout_ms))

    case Budget.acquire(request, timeout_ms: admission_ms, command_timeout_ms: 1_500, lease_timeout_ms: deadline_ms) do
      {:ok, lease} ->
        deadline_at_ms = System.monotonic_time(:millisecond) + deadline_ms

        try do
          result = OffProcess.off_process_request(request, request_fun, deadline_at_ms, deadline_ms)

          :ok =
            Budget.observe(request, lease, result,
              timeout_ms: max(remaining_deadline_ms(deadline_at_ms), 1),
              deadline_at: deadline_at_ms
            )

          quota_observe(quota, request, result)
          result
        after
          Budget.release(lease, deadline_at: deadline_at_ms)
        end

      {:hold, hold} ->
        {:error, {:aiur, :locally_held, HoldPressure.record(hold)}}

      {:error, _reason} = error ->
        error

      :bypass ->
        deadline_at_ms = System.monotonic_time(:millisecond) + deadline_ms
        result = OffProcess.off_process_request(request, request_fun, deadline_at_ms, deadline_ms)
        quota_observe(quota, request, result)
        result
    end
  end

  @spec off_process_request(map(), (-> term())) :: term()
  defdelegate off_process_request(request, request_fun), to: OffProcess

  # The per-attempt `receive_timeout` bounds one socket read; Req retries, so
  # the deadline must cover the whole request including retries. It is a
  # backstop against a wedge, not the primary latency bound.
  #
  # Preserve the tighter deadline for any direct orchestrator request. Poll and
  # control I/O now runs outside that owner, using the ordinary request deadline.
  @spec request_deadline_ms(map()) :: pos_integer()
  def request_deadline_ms(request) do
    case Application.get_env(:aiur, :github_request_deadline_ms) do
      configured when is_integer(configured) and configured > 0 ->
        configured

      _unset ->
        default_request_deadline_ms(request)
    end
  end

  defp default_request_deadline_ms(request) do
    if orchestrator_process?() do
      @orchestrator_request_deadline_ms
    else
      timeout_ms = Map.get(request, :timeout_ms, @default_request_timeout_ms)
      timeout_ms = if is_integer(timeout_ms) and timeout_ms > 0, do: timeout_ms, else: @default_request_timeout_ms

      max(@default_request_deadline_ms, timeout_ms + @deadline_margin_ms)
    end
  end

  defp remaining_deadline_ms(deadline_at_ms),
    do: max(deadline_at_ms - System.monotonic_time(:millisecond), 0)

  defp orchestrator_process?, do: self() == GenServer.whereis(Application.get_env(:aiur, :github_poll_owner))

  defp quota_preflight(quota, request), do: Quota.preflight(quota, request)

  # Every real GitHub response passes here, which makes it the one place that
  # can tell the auth preflight memo its answer went stale. See
  # `Aiur.GitHub.AuthPreflight.note_response/2`.
  #
  # Quota accounting goes first and owns the return value. It gates the whole
  # fleet, so it must not be able to be skipped by a defect in an advisory
  # cache hint that was bolted on after it.
  defp quota_observe(quota, request, result) do
    observed = Quota.observe(quota, request, result)
    # Quota keeps one window per resource; this keeps the same headers per
    # credential so the selector can compare headroom across the pool.
    CredentialHeadroom.observe(request, result)
    AuthPreflight.note_response(request, result)
    observed
  end

  defp request_options(headers, req) do
    options = Application.get_env(:aiur, :github_transport_test_options, [])
    options = if is_list(options) and Keyword.keyword?(options), do: options, else: []
    timeout_ms = Map.get(req, :timeout_ms, @default_request_timeout_ms)

    options
    # The shared budget lease covers one network attempt. Req retries safe
    # transient responses, including 429, by default; allowing that retry here
    # would make one admission hide several GitHub calls and could swallow the
    # response that establishes the fleet-wide cooldown.
    |> Keyword.merge(headers: headers, connect_options: [timeout: timeout_ms], receive_timeout: timeout_ms, retry: false)
    |> OffProcess.maybe_bound_response(req)
  end

  @spec github_headers(String.t() | nil, map()) :: [{String.t(), String.t()}]
  def github_headers(token, req) do
    version =
      case req do
        %{api_version: version} when is_binary(version) -> version
        _no_override -> "2022-11-28"
      end

    base = [
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", version}
    ]

    # A tokenless read is a legitimate anonymous call (public CODEOWNERS, for
    # one). Sending `Bearer ` with no token turns it into a 401 instead, so the
    # header is omitted rather than emitted empty.
    if is_binary(token) and token != "" do
      [{"Authorization", "Bearer #{token}"} | base]
    else
      base
    end
  end

  @spec github_graphql(function(), String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate github_graphql(request_fun, token, query, variables, opts \\ []), to: GraphQL

  @doc """
  Issues a priced and instrumented GraphQL request, returning the body and raw response.

  See `Aiur.GitHub.Transport.GraphQL.github_graphql_response/5` for the request contract.
  """
  @spec github_graphql_response(function(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map(), map()} | {:error, term(), map() | nil}
  defdelegate github_graphql_response(request_fun, token, query, variables, opts \\ []), to: GraphQL

  @spec fetch_json_list(function(), String.t(), String.t(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def fetch_json_list(request_fun, token, url, opts \\ []) do
    request = put_caller(%{method: :get, url: url, token: token}, opts)

    case request_fun.(request) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        with {:ok, list, _etag} <- single_page_list(body, response, nil), do: {:ok, list}

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @doc """
  Fetches a JSON list conditionally and preserves the response ETag.

  A `304 Not Modified` is a successful, budget-free response. Callers keep
  their last materialized value and use the returned ETag on the next request.

  This helper answers exactly one request, so it can only vouch for the page
  GitHub returned. A response that points at a `rel="next"` page is refused
  with `{:error, :pagination_unexpected}` rather than handed to a caller that
  would trust a partial list: a page-1 validator cannot answer a multi-page
  question, so a caller that needs more than one page must use a per-page
  reader or read unconditionally (website/docs-app/apis/github.md, #2330).
  """
  @spec fetch_json_list_conditional(function(), String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, [term()], String.t() | nil} | {:not_modified, String.t() | nil} | {:error, term()}
  def fetch_json_list_conditional(request_fun, token, url, etag \\ nil, opts \\ []) do
    request = %{method: :get, url: url, token: token}
    request = if is_binary(etag) and etag != "", do: Map.put(request, :etag, etag), else: request
    request = put_caller(request, opts)

    case request_fun.(request) do
      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        log_rate_budget_pressure(response)
        single_page_list(body, response, etag)

      {:ok, %{status: 304} = response} ->
        log_rate_budget_pressure(response)
        {:not_modified, header(Map.get(response, :headers, []), "etag") || etag}

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  # A 200 that points at a `rel="next"` page is refused rather than handed to a
  # caller that would trust a partial list: a page-1 validator cannot answer a
  # multi-page question, so a caller that needs more than one page must use a
  # per-page reader or read unconditionally (website/docs-app/apis/github.md).
  defp single_page_list(body, response, etag) do
    if parse_next_page_url(Map.get(response, :headers, [])) do
      {:error, :pagination_unexpected}
    else
      {:ok, body, header(Map.get(response, :headers, []), "etag") || etag}
    end
  end

  @spec fetch_json_map(function(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_json_map(request_fun, token, url, opts \\ []) do
    request = put_caller(%{method: :get, url: url, token: token}, opts)

    case request_fun.(request) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: _status} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @doc """
  Stamps the declared call site onto a REST request map, so the cost of the
  read is attributed to its caller rather than to the endpoint it happens to
  hit.

  GraphQL requests get this from `send_graphql/5`. REST requests are built in
  many places — several of them build the request map by hand and hand it
  straight to the `request_fun` — so the same declaration is available here for
  those builders. A request already carrying a `:caller` is left untouched, and
  a request with none is unchanged, so this is safe to call on any request map.
  """
  @spec put_caller(map(), keyword()) :: map()
  def put_caller(request, opts) when is_map(request) and is_list(opts) do
    case Keyword.get(opts, :caller) do
      caller when is_atom(caller) and not is_nil(caller) -> Map.put(request, :caller, Atom.to_string(caller))
      caller when is_binary(caller) and caller != "" -> Map.put(request, :caller, caller)
      _undeclared -> request
    end
  end

  @spec parse_next_page_url(list() | map()) :: String.t() | nil
  def parse_next_page_url(headers) do
    case header(headers, "link") do
      value when is_binary(value) ->
        Regex.run(~r/<([^>]+)>;\s*rel="next"/, value)
        |> case do
          [_, next_url] -> next_url
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @spec maybe_put_query(map(), String.t(), term()) :: map()
  def maybe_put_query(query, _key, nil), do: query
  def maybe_put_query(query, key, value), do: Map.put(query, key, value)

  @spec header(term(), String.t()) :: term() | nil
  def header(headers, name) when is_list(headers) do
    name_down = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} ->
        if String.downcase(to_string(key)) == name_down do
          List.wrap(value) |> List.first()
        end

      _ ->
        nil
    end)
  end

  def header(headers, name) when is_map(headers) do
    name_down = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name_down do
        List.wrap(value) |> List.first()
      end
    end)
  end

  def header(_headers, _name), do: nil

  @doc false
  @spec log_rate_budget_pressure(map()) :: :ok | nil
  def log_rate_budget_pressure(response) do
    remaining = GraphQLErrors.rate_limit_remaining(response)
    limit = header(Map.get(response, :headers, []), "x-ratelimit-limit") |> parse_nonnegative_integer()

    if is_integer(remaining) and is_integer(limit) and limit > 0 and remaining * 10 <= limit do
      resource = header(Map.get(response, :headers, []), "x-ratelimit-resource") || "unknown"
      reset_at = GraphQLErrors.rate_limit_reset(response) || "unknown"

      Logger.warning("github_rate_budget_pressure resource=#{resource} remaining=#{remaining} limit=#{limit} reset_at=#{reset_at}")
    end
  end

  defp parse_nonnegative_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_nonnegative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp parse_nonnegative_integer(_value), do: nil

  @spec poll_interval(list() | map()) :: pos_integer()
  def poll_interval(headers) do
    case header(headers, "x-poll-interval") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n > 0 -> n
          _ -> 60
        end

      _ ->
        60
    end
  end
end
