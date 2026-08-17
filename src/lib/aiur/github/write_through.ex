defmodule Aiur.GitHub.WriteThrough do
  @moduledoc """
  Deposits the state Aiur's own GitHub mutations return into
  `Aiur.GitHub.ResourceStore`.

  Every Aiur-originated change to GitHub — an agent posting a comment, the
  orchestrator applying a label, a ticket closed, a pull request's base
  repaired, a review thread replied to — comes back from the API carrying the
  new state. Aiur has historically thrown that response away and then, minutes
  later, paid full price to read back a change it made itself.

  This module is the writer that removes that class of read. It is the cheapest
  writer in the design because it costs nothing at all: the round trip was
  already required by the mutation, so the state is free and it arrives before
  any webhook for the same change could. Views subscribed to the resource
  re-render off the deposit rather than off a timer.

  ## Suppressing our own echo

  GitHub delivers a webhook for a change Aiur made, moments after Aiur made it.
  Left alone that delivery re-wakes agents for their own writes — the
  `bot_account` self-loop, reappearing one layer down. So a deposit that can
  name the resource's `updated_at` also *marks it processed at that version*,
  and `Aiur.Events.Publisher` recognises the delivery that follows as
  already-handled. Version equality is what keeps this from over-reaching: a
  later genuine edit moves `updated_at`, so it is published as normal.

  A response that cannot name a version — GitHub's label endpoints return the
  label array and nothing else — deposits the state without marking anything.
  Marking with no version would suppress on identity alone and swallow the
  resource's next real change.

  ## What deliberately does not write through

  The mutation surface was enumerated by grepping the single REST transport for
  `method: :post | :patch | :delete` and the GraphQL path for `mutation`, rather
  than from a list, so the exclusions below are decisions and not oversights:

    * `Aiur.GitHub.AppToken` — a `POST` for an installation access token. Not
      GitHub *state*; caching a credential in a resource store would be wrong.
    * `Aiur.GitHub.Labels.ensure/5` — creates a repository's label
      *definitions* at `aiur init`. Repo configuration, read by nothing that
      renders, and once per repo rather than per ticket.
    * `Aiur.TestReset` — closes pull requests through the `gh` CLI as a
      development reset, outside the daemon's runtime paths entirely.

  ## Pull request creation, review submission, and body edits

  These are named in the unit's contract and are deliberately **not** here,
  because Aiur's Elixir client does not perform them. There is no `POST
  .../pulls`, no `POST .../pulls/:n/reviews`, and no issue-body `PATCH` anywhere
  under `Aiur.GitHub`: agents open pull requests, submit reviews and edit ticket
  bodies by running `gh` inside their own workspace, through the wrapper
  `Aiur.AgentGitHubGuard` installs. The two whole-resource `PATCH`es Aiur does
  own both write through — the pull request base repair in
  `Aiur.GitHub.PullRequests` and the ticket close in `Aiur.GitHub.IssueState`.

  Depositing an agent's `gh` mutation therefore means teaching that wrapper to
  keep the response it already receives, which is the same seam U6 opens to
  route the wrapper's *reads* through the store. It is left to U6 on purpose:
  a shell-side deposit would have to duplicate this module's key-building and
  repo-identity logic in Bash before the Elixir side has a wrapper-facing entry
  point to call. Nothing here needs to change for that to land — these writer
  functions are already the right grain.

  ## Never the mutation's problem

  Every function here answers `:ok` whatever happens, and the whole body is
  guarded. A cache that cannot record something must cost a later fetch, never
  a failed write: the mutation has already succeeded upstream by the time it
  gets here, and nothing about caching its result may change what the caller
  sees.
  """

  require Logger

  alias Aiur.GitHub.{ResourceStore, Transport}

  @doc """
  Deposits an issue comment from a `POST .../issues/:number/comments` response.
  """
  @spec issue_comment(term(), keyword()) :: :ok
  def issue_comment(comment, opts \\ []) do
    guarded(fn ->
      deposit(:issue_comment, comment_id(comment), comment, comment_version(comment), opts)
    end)
  end

  @doc """
  Deposits a pull request review comment.

  Accepts both the REST shape and the GraphQL shape returned by
  `addPullRequestReviewThreadReply`, whose `databaseId` is the same id the
  `pull_request_review_comment` delivery carries — which is what lets the
  deposit suppress the delivery.
  """
  @spec pr_review_comment(term(), keyword()) :: :ok
  def pr_review_comment(comment, opts \\ []) do
    guarded(fn ->
      deposit(:pr_review_comment, comment_id(comment), comment, comment_version(comment), opts)
    end)
  end

  @doc "Deposits a whole issue from a `PATCH .../issues/:number` response."
  @spec issue(term(), keyword()) :: :ok
  def issue(issue, opts \\ []) do
    guarded(fn ->
      deposit(:issue, resource_number(issue), issue, comment_version(issue), opts)
    end)
  end

  @doc "Deposits a whole pull request from a `PATCH .../pulls/:number` response."
  @spec pull_request(term(), keyword()) :: :ok
  def pull_request(pull_request, opts \\ []) do
    guarded(fn ->
      deposit(:pull_request, resource_number(pull_request), pull_request, comment_version(pull_request), opts)
    end)
  end

  @doc """
  Deposits an issue's labels from a label add or remove response.

  GitHub answers both endpoints with the issue's complete label array, so a
  single label write leaves the store holding the whole truthful set. The held
  issue body, if there is one, has its `"labels"` replaced in the same pass so a
  view rendering the issue sees the new label without a fetch — which is the
  point of the unit.
  """
  @spec issue_labels(term(), term(), keyword()) :: :ok
  def issue_labels(issue_number, labels, opts \\ []) do
    guarded(fn ->
      with true <- is_list(labels),
           {:ok, owner, repo} <- repo_identity(nil, opts),
           key when not is_nil(key) <- ResourceStore.key(:issue_labels, owner, repo, issue_number) do
        ResourceStore.put_resource(key, labels, source: source(opts))
        merge_issue_labels(owner, repo, issue_number, labels, opts)
      else
        _other -> :ok
      end
    end)
  end

  @doc """
  Deposits a review thread's resolution state from a resolve/unresolve mutation.

  The mutation answers with the thread's node id and `isResolved` and no
  version, so this deposits state without marking anything processed.
  """
  @spec review_thread(term(), keyword()) :: :ok
  def review_thread(thread, opts \\ []) do
    guarded(fn ->
      deposit(:pr_review_thread, node_id(thread), thread, nil, opts)
    end)
  end

  # -- internals ------------------------------------------------------------

  defp deposit(_type, nil, _data, _version, _opts), do: :ok

  defp deposit(type, id, data, version, opts) do
    case repo_identity(data, opts) do
      {:ok, owner, repo} ->
        # `processed:` is gated on holding a real version, never on the type.
        # A mark with no version suppresses on identity alone, which would
        # swallow the resource's next genuine change for the whole retention
        # window.
        ResourceStore.put_resource(ResourceStore.key(type, owner, repo, id), data,
          source: source(opts),
          version: version,
          processed: is_binary(version)
        )

      :error ->
        :ok
    end
  end

  defp merge_issue_labels(owner, repo, issue_number, labels, opts) do
    key = ResourceStore.key(:issue, owner, repo, issue_number)

    case ResourceStore.fetch(key) do
      {:ok, %{data: %{} = issue}} ->
        # No version is claimed: a labels-only response cannot name the issue's
        # new `updated_at`, and inventing one would let this body outrank a
        # writer that genuinely knows.
        ResourceStore.put_resource(key, Map.put(issue, "labels", labels), source: source(opts))

      _other ->
        :ok
    end
  end

  defp source(opts), do: Keyword.get(opts, :source, :mutation)

  # The repository the deposit belongs to. Preferring the response's own URL
  # over configuration is what keeps the key identical to the one the webhook
  # pipe builds from `repository.full_name`; configuration is the fallback for
  # a response that carries no URL, and every Aiur mutation targets it anyway.
  defp repo_identity(data, opts) do
    case Keyword.get(opts, :repo) || repo_from_body(data) do
      full_name when is_binary(full_name) ->
        case String.split(full_name, "/") do
          [owner, repo] when owner != "" and repo != "" -> {:ok, owner, repo}
          _other -> configured_repo()
        end

      _other ->
        configured_repo()
    end
  end

  defp configured_repo do
    case Transport.parse_repo() do
      {:ok, {owner, repo}} -> {:ok, owner, repo}
      _other -> :error
    end
  end

  defp repo_from_body(%{"repository_url" => url}) when is_binary(url), do: repo_from_url(url, "/repos/")
  defp repo_from_body(%{"html_url" => url}) when is_binary(url), do: repo_from_url(url, "github.com/")
  defp repo_from_body(_data), do: nil

  defp repo_from_url(url, marker) do
    case String.split(url, marker, parts: 2) do
      [_prefix, rest] ->
        case String.split(rest, "/") do
          [owner, repo | _tail] when owner != "" and repo != "" -> "#{owner}/#{repo}"
          _other -> nil
        end

      _other ->
        nil
    end
  end

  # `databaseId` outranks `id` deliberately. A GraphQL response carries both,
  # and only `databaseId` is the id the REST pipes and the webhook delivery
  # use — keying on the node id would file the deposit where nothing else can
  # find it, which is the exact failure keying by identity exists to prevent.
  defp comment_id(%{"databaseId" => id}) when is_integer(id) or (is_binary(id) and id != ""), do: id
  defp comment_id(%{"id" => id}) when is_integer(id) or (is_binary(id) and id != ""), do: id
  defp comment_id(_comment), do: nil

  defp resource_number(%{"number" => number}) when is_integer(number) or (is_binary(number) and number != ""), do: number
  defp resource_number(_resource), do: nil

  defp node_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp node_id(_thread), do: nil

  defp comment_version(%{"updated_at" => at}) when is_binary(at) and at != "", do: at
  defp comment_version(%{"updatedAt" => at}) when is_binary(at) and at != "", do: at
  defp comment_version(_resource), do: nil

  # A write-through fault is a lost cache entry and nothing more. The mutation
  # it followed has already landed on GitHub, so raising here would report a
  # failure that did not happen and, worse, invite a retry that posts twice.
  defp guarded(fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.debug("GitHub write-through skipped: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.debug("GitHub write-through skipped: #{inspect({kind, reason})}")
      :ok
  end
end
