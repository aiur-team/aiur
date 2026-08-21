defmodule Aiur.GitHub.ReadCache.Identity do
  @moduledoc """
  What a GitHub request is *about*, derived from the request itself.

  The daemon's cache is keyed by resource identity rather than by query text,
  for the reason `Aiur.GitHub.AgentCache` gives: a resource is read in many
  shapes, and a writer that has to enumerate the shapes it retires will always
  miss one. Identity is the join. A mutation to pull request 2073 must be able
  to retire a batch document that mentions 2073 among thirty-two other numbers
  without ever having seen that document.

  ## Identities are extracted, not declared

  Nothing in this module asks the call site for anything. `CiPollBatch` and
  `CommentPollBatch` interpolate ticket numbers **into the GraphQL document**
  and send only `owner`/`repo` as variables, so a version of this that read
  `variables` alone would derive one repository identity for a query about
  thirty-three tickets, and one mutation would either retire everything or
  nothing. The document is therefore scanned for the numbers it names.

  Extraction is deliberately over-broad. A number this finds that is not really
  a resource costs one spurious invalidation; a number it misses serves stale
  state. Those are not the same mistake.

  ## Issues and pull requests share one namespace

  GitHub numbers issues and pull requests from a single sequence, and
  `gh issue comment 2073` changes what a pull-request query about 2073 answers.
  `AgentCache.invalidate/3` handles this by marking `pr/<id>` *and*
  `issue/<id>` on every write. Here the two spellings collapse into one
  `{:number, owner, repo, n}` identity instead, so the sharing is structural:
  there is no second name that could be forgotten.

  ## Scopes

  Each request yields a list of identities, from coarse to fine:

    * `:root` — everything. Held by every entry, so one marker empties the store.
    * `{:repo, owner, repo}` — every read of one repository.
    * `{:collections, owner, repo}` — reads that enumerate (issue lists, search,
      batch documents). A created issue makes every list wrong and no individual
      resource wrong, which is the distinction `github_quota_guard.sh` draws
      between a `collection` write and a numbered one.
    * `{:number, owner, repo, n}` — one issue-or-pull-request number.

  An entry is retired when **any** identity it carries is invalidated.
  """

  @base_url "https://api.github.com"

  @type t ::
          :root
          | {:repo, String.t(), String.t()}
          | {:collections, String.t(), String.t()}
          | {:number, String.t(), String.t(), pos_integer()}

  # `pullRequest(number: 2073)`, `issue(number: 2073)`, `t0: pullRequest(number: 2073)`,
  # and the bare `number: 2073` argument the batch builders emit.
  @document_number ~r/\bnumber\s*:\s*(\d+)/
  @rest_number ~r{/(?:issues|pulls)/(\d+)(?:/|$|\?)}
  @rest_repo ~r{/repos/([^/?#]+)/([^/?#]+)}
  # Selections whose answer changes when a resource is *created*, so the entry
  # must also be retired by the collections marker.
  @enumerating ~r/headRefName\s*:|\bsearch\s*\(|\bpullRequests\s*\(|\bissues\s*\(/

  @doc """
  The identities a request observes, coarsest first.

  Answers `[]` for a request whose repository cannot be named. A request with no
  identity is uncacheable rather than cacheable-under-`:root`: an entry that only
  `:root` can retire survives every ordinary write, which is the failure mode
  that produces a cache nobody can invalidate.
  """
  @spec extract(map()) :: [t()]
  def extract(request) when is_map(request) do
    case repository(request) do
      {owner, repo} -> [:root, {:repo, owner, repo}] ++ scoped(request, owner, repo)
      nil -> []
    end
  end

  def extract(_request), do: []

  @doc """
  The repository a request names, down-cased, or `nil`.

  Down-cased for the reason `ResourceStore.key/4` down-cases: the poller uses the
  configured repo identity and webhook payloads use GitHub's delivered
  `full_name`, and an exact-match store files one repository under two names and
  is then permanently cold.
  """
  @spec repository(map()) :: {String.t(), String.t()} | nil
  def repository(%{url: url, body: %{"variables" => variables}}) when is_binary(url) do
    if graphql?(url), do: repository_from_variables(variables), else: repository_from_url(url)
  end

  def repository(%{url: url}) when is_binary(url), do: repository_from_url(url)
  def repository(_request), do: nil

  @doc "Whether the request is the GraphQL endpoint."
  @spec graphql?(String.t()) :: boolean()
  def graphql?(url) when is_binary(url), do: String.starts_with?(url, "#{@base_url}/graphql")
  def graphql?(_url), do: false

  @doc """
  The GraphQL document a request carries, or `nil` for a REST request.

  Read from the request rather than from the caller's argument because the
  document that matters is the instrumented one that was actually sent — the
  same object the response answered.
  """
  @spec document(map()) :: String.t() | nil
  def document(%{body: %{"query" => query}}) when is_binary(query), do: query
  def document(_request), do: nil

  @doc """
  Whether a GraphQL document is a mutation.

  Anything but a plain `query`/anonymous document is treated as a write. The
  test is on the leading keyword because a `mutation` named after a query type,
  or a document with both, still writes.
  """
  @spec mutation?(map()) :: boolean()
  def mutation?(request) do
    case document(request) do
      nil -> false
      doc -> Regex.match?(~r/(\A|\n)\s*mutation\b/, doc)
    end
  end

  defp scoped(request, owner, repo) do
    numbers = numbers(request)

    collection =
      if collection?(request, numbers), do: [{:collections, owner, repo}], else: []

    collection ++ Enum.map(numbers, &{:number, owner, repo, &1})
  end

  # A read that names no number enumerates something, whatever it is called: an
  # issue list, a search, a review-thread sweep. It is retired by the collections
  # marker, which is what a newly created resource writes.
  #
  # Naming numbers does not make a read safe from the collections marker. Both
  # poll batches ask `pullRequests(headRefName: "...")` — "is there an open pull
  # request on this branch yet" — and the answer changes when a pull request is
  # *created*, an event that touches none of the numbers the document already
  # names. A document that enumerates carries both scopes.
  defp collection?(_request, []), do: true

  defp collection?(request, _numbers) do
    case document(request) do
      nil -> false
      doc -> Regex.match?(@enumerating, doc)
    end
  end

  defp numbers(request) do
    from_document = scan(document(request), @document_number)
    from_url = scan(Map.get(request, :url), @rest_number)
    from_variables = variable_numbers(request)

    (from_document ++ from_url ++ from_variables) |> Enum.uniq() |> Enum.sort()
  end

  defp scan(nil, _regex), do: []

  defp scan(subject, regex) when is_binary(subject) do
    regex
    |> Regex.scan(subject)
    |> Enum.flat_map(fn [_match, captured] -> parse_number(captured) end)
  end

  defp scan(_subject, _regex), do: []

  defp variable_numbers(%{body: %{"variables" => variables}}) when is_map(variables) do
    variables
    |> Map.take(["number", "issueNumber", "prNumber", "pullRequestNumber"])
    |> Map.values()
    |> Enum.flat_map(&parse_number/1)
  end

  defp variable_numbers(_request), do: []

  defp parse_number(value) when is_integer(value) and value > 0, do: [value]

  defp parse_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> [parsed]
      _other -> []
    end
  end

  defp parse_number(_value), do: []

  defp repository_from_variables(variables) when is_map(variables) do
    owner = Map.get(variables, "owner") || Map.get(variables, "repositoryOwner")
    # Three spellings are in use for the same argument: `repo` (both poll
    # batches), `name` (`BuildOrder.PackStatus`) and `repository`
    # (`IssueRelationships`). All three are read here rather than normalised at
    # the call sites, because the call sites are what this cache exists not to
    # have to change.
    repo = Map.get(variables, "repo") || Map.get(variables, "name") || Map.get(variables, "repository")

    normalize_repository(owner, repo)
  end

  defp repository_from_variables(_variables), do: nil

  defp repository_from_url(url) do
    case Regex.run(@rest_repo, url) do
      [_match, owner, repo] -> normalize_repository(owner, repo)
      _other -> nil
    end
  end

  defp normalize_repository(owner, repo) when is_binary(owner) and is_binary(repo) do
    if owner != "" and repo != "", do: {String.downcase(owner), String.downcase(repo)}, else: nil
  end

  defp normalize_repository(_owner, _repo), do: nil
end
