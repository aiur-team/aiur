defmodule Aiur.GitHub.AgentCache do
  @moduledoc """
  The daemon's half of the agent `gh` state cache (#2073 U6).

  `priv/github_quota_guard.sh` serves agent reads from a directory of replayed
  `gh` responses beside the budget broker's database. This module is how the
  daemon tells that store something changed.

  ## Why the agent store replays bytes instead of reading `ResourceStore`

  `Aiur.GitHub.ResourceStore` holds **API response bodies**. The wrapper must
  answer with **`gh` stdout**, and the two are not the same artifact. A single
  `gh pr view 2073 --json body -q .body` puts three transformations between the
  API response and the bytes the agent reads: `gh`'s GraphQL field projection,
  Go's `encoding/json` (which escapes `<`, `>` and `&` as `\\u003c`, `\\u003e`
  and `\\u0026`), and `gh`'s embedded `gojq`. Rebuilding that chain in shell to
  serve a stored REST body would be imitation, and an imitation that is subtly
  wrong corrupts agent input without ever raising — strictly worse than a cache
  miss.

  So the wrapper stores the exact stdout the real `gh` produced, keyed by
  resource identity with the output-affecting arguments hashed into the
  filename. Byte-identity then holds by construction rather than by care.

  ## What this module is for

  Identity is the join between the two stores. The wrapper checks an
  `.invalidated` marker inside each resource's directory before serving, so any
  daemon writer can retire every cached shape of a resource — including shapes
  it has never heard of — by writing one timestamp:

      # a webhook delivery, a mutation write-through, a need-driven fetch
      Aiur.GitHub.AgentCache.invalidate("aiur-team/aiur", 2073)

  This is the free half of the plan working end to end: a delivery that cost
  nothing stops sixteen agents from paying to discover the same change.

  ## Numbers are shared between issues and pull requests

  GitHub numbers issues and pull requests from one sequence, and `gh issue
  comment 2073` changes what `gh pr view 2073 --json comments` answers. Every
  invalidation therefore marks both, which is why `invalidate/3` takes a number
  rather than a resource type — there is no correct way to mark only one.

  ## Failure is silent by design

  Every function answers `:ok`. An unwritable or absent store means agents keep
  their entries until those expire on their own freshness window, which costs at
  most one stale window and never costs a failed daemon operation. The store is
  a cache, not the system of record.
  """

  require Logger

  alias Aiur.GitHub.{Budget, ResourceStore}

  @relative_root "state-cache/v1"

  @doc """
  The store root the `gh` wrapper reads, or `nil` when the budget state
  directory is unavailable.

  Kept in one place because the wrapper derives the same path from
  `AIUR_GITHUB_BUDGET_ROOT`; if these two ever disagree the daemon marks
  resources no agent is reading.
  """
  @spec root(keyword()) :: Path.t() | nil
  def root(opts \\ []) do
    case Budget.state_dir(opts) do
      dir when is_binary(dir) and dir != "" -> Path.join(dir, @relative_root)
      _other -> nil
    end
  end

  @doc """
  Retires every cached shape of one issue or pull request.

  `full_name` is `"owner/repo"` — the same identity spelling
  `Aiur.GitHub.ResourceStore.key_for_repo/3` accepts, so a caller holding a
  webhook's `repository.full_name` can write to both stores from one value. A
  number that is not a positive integer is ignored rather than guessed at.
  """
  @spec invalidate(String.t(), String.t() | integer(), keyword()) :: :ok
  def invalidate(full_name, number, opts \\ []) do
    with {:ok, repo_dir} <- repo_dir(full_name, opts),
         {:ok, id} <- normalize_number(number) do
      # Both number spaces, and the collections that list them: a body edit
      # changes `gh issue list --json title` as surely as it changes the ticket.
      mark(Path.join([repo_dir, "pr", id, ".invalidated"]))
      mark(Path.join([repo_dir, "issue", id, ".invalidated"]))
      mark(Path.join(repo_dir, ".collections-invalidated"))
    else
      _unavailable -> :ok
    end
  end

  @doc """
  Retires every cached read of a repository.

  For a change whose subject cannot be named — a label renamed across a repo, a
  webhook whose payload did not survive normalisation. Over-invalidating costs
  one re-fetch; under-invalidating serves a stale answer for a whole window.
  """
  @spec invalidate_repo(String.t(), keyword()) :: :ok
  def invalidate_repo(full_name, opts \\ []) do
    case repo_dir(full_name, opts) do
      {:ok, repo_dir} -> mark(Path.join(repo_dir, ".invalidated"))
      _unavailable -> :ok
    end
  end

  @doc """
  Retires a repository's cached collection queries, leaving individual resources
  alone.

  The write-through case for a created issue or pull request: nothing existing
  went stale, but every list that should now contain it did.
  """
  @spec invalidate_collections(String.t(), keyword()) :: :ok
  def invalidate_collections(full_name, opts \\ []) do
    case repo_dir(full_name, opts) do
      {:ok, repo_dir} -> mark(Path.join(repo_dir, ".collections-invalidated"))
      _unavailable -> :ok
    end
  end

  @doc """
  Where the `gh` wrapper keeps every cached shape of one resource, or `nil` for a
  resource the wrapper has no directory for.

  This is the join between the two halves, and the reason it takes a
  `Aiur.GitHub.ResourceStore` key rather than strings: a shell reader and an
  Elixir writer that disagree on where a resource lives produce a cache that is
  always cold and always looks healthy. One function derives the path, and
  `Aiur.AgentGitHubGuardTest` asserts it against the directory the wrapper
  actually created for the same resource.
  """
  @spec resource_dir(ResourceStore.key() | nil, keyword()) :: Path.t() | nil
  def resource_dir(key, opts \\ [])

  def resource_dir({type, owner, repo, id}, opts) do
    with kind when is_binary(kind) <- wrapper_kind(type),
         {:ok, repo_dir} <- repo_dir("#{owner}/#{repo}", opts),
         {:ok, normalized} <- normalize_number(id) do
      Path.join([repo_dir, kind, normalized])
    else
      _unavailable -> nil
    end
  end

  def resource_dir(_key, _opts), do: nil

  @doc """
  Retires every cached shape of the resource a store key names.

  The bridge from `Aiur.GitHub.ResourceStore`'s change events: a webhook
  delivery, a mutation write-through or a need-driven fetch deposits a resource
  in the store, and the agents' copies of it stop being served in the same
  moment. That is the whole point of the store being keyed by identity — a fact
  learned for free down one pipe retires the paid reads down another.
  """
  @spec invalidate_key(ResourceStore.key() | nil, keyword()) :: :ok
  def invalidate_key(key, opts \\ [])

  def invalidate_key({_type, owner, repo, id} = key, opts) do
    case resource_dir(key, opts) do
      dir when is_binary(dir) ->
        mark(Path.join(dir, ".invalidated"))
        # Issues and pull requests share GitHub's number space, so the sibling
        # spelling of the same number is retired too.
        invalidate("#{owner}/#{repo}", id, opts)

      nil ->
        # A resource type the wrapper files nothing under — a comment, a review
        # thread — still changes what a read of its parent would answer, and the
        # parent's number is not derivable from the comment's id. The
        # repository's collections are retired instead: one re-fetch rather than
        # a stale answer for a whole window.
        invalidate_collections("#{owner}/#{repo}", opts)
    end
  end

  def invalidate_key(_key, _opts), do: :ok

  # The wrapper's two resource directories. Everything else has no agent-side
  # directory, and is deliberately not invented one here: a name the wrapper does
  # not write is a mark nothing will ever read.
  defp wrapper_kind(:pull_request), do: "pr"
  defp wrapper_kind(:issue), do: "issue"
  defp wrapper_kind(_type), do: nil

  # Down-cased, matching `ResourceStore.key/4`. The two pipes disagree on casing —
  # the poller uses the configured repo identity and the webhook uses GitHub's
  # delivered `repository.full_name` — and the wrapper down-cases for the same
  # reason. An exact-match layout would file the same repository under two names.
  defp repo_dir(full_name, opts) when is_binary(full_name) do
    with [owner, repo] <- full_name |> String.downcase() |> String.split("/"),
         true <- safe_segment?(owner),
         true <- safe_segment?(repo),
         path when is_binary(path) <- root(opts) do
      {:ok, Path.join([path, owner, repo])}
    else
      _unavailable -> :error
    end
  end

  defp repo_dir(_full_name, _opts), do: :error

  # Path segments come from webhook payloads, so they are attacker-influenced
  # input to a filesystem write. Anything outside this alphabet — a separator, a
  # traversal, an empty segment — is refused rather than escaped.
  defp safe_segment?(segment) do
    segment not in ["", ".", ".."] and String.match?(segment, ~r{\A[\w.-]+\z})
  end

  defp normalize_number(number) when is_integer(number) and number > 0,
    do: {:ok, Integer.to_string(number)}

  defp normalize_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> {:ok, Integer.to_string(parsed)}
      _other -> :error
    end
  end

  defp normalize_number(_number), do: :error

  # Temp-and-rename, matching `write_hold/2` in the wrapper: a truncating write
  # leaves the marker momentarily empty, and an agent sampling it in that gap
  # reads "never invalidated" and serves the entry this call exists to retire.
  defp mark(path) do
    temporary = "#{path}.#{System.unique_integer([:positive])}.tmp"
    stamp = "#{System.system_time(:second)}\n"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, stamp),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        Logger.debug("agent gh cache invalidation skipped path=#{path} reason=#{inspect(reason)}")
        :ok
    end
  end
end
