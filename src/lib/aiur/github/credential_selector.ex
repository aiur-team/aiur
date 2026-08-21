defmodule Aiur.GitHub.CredentialSelector do
  @moduledoc """
  Picks which credential a GitHub request spends.

  The broker was already per-credential — every table in `priv/github_budget.py`
  leads with `token_key` — so what was missing was never storage, it was a
  chooser. This is the chooser.

  ## The algorithm

  For a request, `select/2`:

  1. Derives the **resource** (`graphql` or `core`) and the **intent**
     (`:read` or `:write`). Core and GraphQL are separate GitHub budgets on
     separate windows and are therefore selected independently: REST core sitting
     near-idle is not headroom a GraphQL query can spend.
  2. Filters the registry to credentials eligible for that intent.
     Reads may use the whole pool; writes may only use credentials explicitly
     marked `writes: true`, which never includes a `human` credential.
  3. Drops credentials that are **blocked**: observed `remaining == 0` inside a
     window that has not yet reset. If that leaves nothing, the block is ignored
     and the primary is used — a request refused locally and a request refused by
     GitHub cost the same nothing, but only one of them tells us the window
     rolled.
  4. Scores each survivor by **remaining budget for that resource**:
     an observed fresh window contributes its `remaining`; a credential with no
     observation contributes an optimistic `@assumed_remaining`, because a
     credential the daemon has not called is the one most likely to be full.
  5. Picks the highest score. **Ties break toward the primary**, then by registry
     order. This is what makes the single-credential case bit-identical: one
     candidate, no comparison, the legacy token.

  ## What it does not do

  It does not consult the broker's admission counters on the request path.
  `Aiur.GitHub.Budget.usage/1` spawns a Python process against SQLite; running
  that per request would trade an API-budget problem for a fork-per-request
  problem. The broker's per-`token_key` counters are wired into reporting and
  are available here through the `:usage` option for callers that already hold a
  snapshot. The request path uses the response headers it gets for free.
  """

  alias Aiur.GitHub.{Budget, Credential, CredentialHeadroom, CredentialRegistry}

  # GitHub's per-credential hourly ceiling for both primary budgets. Only used
  # as the optimistic score for an unobserved credential; every observed figure
  # comes from that credential's own headers.
  @assumed_remaining 5_000

  @type intent :: Credential.intent()

  @doc """
  The request with its `:token` (and `:credential_id`) set to the selected
  credential.

  Returns the request untouched when pooling is not configured, which is the
  default. One credential means there is nothing to choose and the legacy path
  must stay exactly as it was.
  """
  @spec assign(map(), keyword()) :: map()
  def assign(request, opts \\ [])

  def assign(%{token: token} = request, opts) when is_binary(token) do
    if CredentialRegistry.pooled?(opts) do
      case select(request, opts) do
        %Credential{} = credential -> apply_credential(request, credential)
        _none -> request
      end
    else
      request
    end
  end

  def assign(request, _opts), do: request

  @doc "The credential this request should spend, or `nil` when none resolves."
  @spec select(map(), keyword()) :: Credential.t() | nil
  def select(request, opts \\ []) do
    choose(resource(request), intent(request), opts)
  end

  @doc """
  The credential with the most headroom for `resource` that may carry `intent`.
  """
  @spec choose(String.t(), intent(), keyword()) :: Credential.t() | nil
  def choose(resource, intent, opts \\ []) do
    credentials = CredentialRegistry.credentials(opts)
    primary = Enum.find(credentials, & &1.primary?) || List.first(credentials)
    eligible = Enum.filter(credentials, &Credential.eligible?(&1, intent))

    case eligible do
      [] -> if intent == :read, do: primary
      [only] -> only
      many -> best(many, resource, primary, opts)
    end
  end

  @doc """
  Whether a request writes.

  A REST `GET` is a read. Everything else on REST is a write. A GraphQL POST is
  a read unless its document contains a `mutation` operation — GraphQL sends
  reads over POST, and treating the whole endpoint as writes would pin the
  entire polling burn (the thing actually exhausting the budget) to one
  credential and leave the pool idle.
  """
  @spec intent(map()) :: intent()
  def intent(%{method: :get}), do: :read

  def intent(%{url: url} = request) when is_binary(url) do
    if URI.parse(url).path == "/graphql", do: graphql_intent(request), else: :write
  end

  def intent(_request), do: :write

  @doc """
  Per-credential headroom rows for reporting.

  Each row carries the credential, its `token_key`, and the observed window per
  resource — `nil` where nothing has been observed, never `0`. Unobserved and
  exhausted are opposite facts and the report must not conflate them.
  """
  @spec headroom(keyword()) :: [map()]
  def headroom(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    windows = Keyword.get_lazy(opts, :windows, fn -> CredentialHeadroom.snapshot(now) end)

    opts
    |> CredentialRegistry.configured()
    |> Enum.map(fn credential ->
      token_key = Credential.token_key(credential)

      %{
        id: credential.id,
        kind: credential.kind,
        identity: credential.identity,
        writes?: credential.writes?,
        primary?: credential.primary?,
        available?: token_key != nil,
        token_key: token_key,
        windows: Map.get(windows, token_key, %{})
      }
    end)
  end

  # A document we cannot read is a write. Misreading a read as a write only
  # costs the pool some headroom; misreading a write as a read puts someone
  # else's name on a comment.
  defp graphql_intent(request) do
    case graphql_document(request) do
      document when is_binary(document) ->
        if Regex.match?(~r/(\A|[\s{])mutation[\s({]/, document), do: :write, else: :read

      _unreadable ->
        :write
    end
  end

  defp graphql_document(%{body: %{query: query}}) when is_binary(query), do: query
  defp graphql_document(%{body: %{"query" => query}}) when is_binary(query), do: query
  defp graphql_document(_request), do: nil

  defp resource(request), do: Budget.request_resource(request)

  defp best(credentials, resource, primary, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    scored = Enum.map(credentials, &{&1, score(&1, resource, now, opts)})
    open = Enum.reject(scored, fn {_credential, score} -> score == :blocked end)

    case open do
      # Every eligible credential reads as exhausted. Rather than refuse the
      # request locally, hand it to the primary and let GitHub be the authority
      # on whether the window has rolled.
      [] -> primary
      candidates -> pick(candidates, primary)
    end
  end

  defp pick(candidates, primary) do
    {best_credential, best_score} = Enum.max_by(candidates, fn {_credential, score} -> score end)

    if primary && Enum.any?(candidates, fn {credential, score} -> credential.id == primary.id and score == best_score end),
      do: primary,
      else: best_credential
  end

  # `:blocked` when the credential's own window says it has nothing left and has
  # not reset; otherwise the remaining points, or an optimistic assumption for a
  # credential that has never been observed.
  defp score(credential, resource, now, opts) do
    case observed_window(credential, resource, now, opts) do
      %{remaining: 0} -> :blocked
      %{remaining: remaining} -> remaining
      _unobserved -> @assumed_remaining
    end
  end

  defp observed_window(credential, resource, now, opts) do
    token_key = Credential.token_key(credential)

    case Keyword.fetch(opts, :windows) do
      {:ok, windows} -> windows |> Map.get(token_key, %{}) |> Map.get(resource)
      :error -> CredentialHeadroom.window(token_key, resource, now)
    end
  end

  defp apply_credential(request, credential) do
    case Credential.token(credential) do
      token when is_binary(token) -> request |> Map.put(:token, token) |> Map.put(:credential_id, credential.id)
      _unavailable -> request
    end
  end
end
