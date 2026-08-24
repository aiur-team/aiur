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

  ## The daemon also reads here — one direction of a two-store sync (#2413)

  The ownership answer to "three stores with no relationship is not a design"
  is: **two stores with a documented sync**, joined by identity, and the join is
  this module. `ResourceStore` is one half (API bodies the daemon reads), the
  wrapper's replay store is the other (`gh` stdout the agents read), and they
  deliberately do not share bytes — the replay-vs-read reason above is exactly
  why. Invalidation has always flowed out of `ResourceStore` into the wrapper
  (`AgentCacheBridge`). Since #2413 the **read** direction exists too:
  `read_body/2` serves a number-addressed resource the daemon would otherwise
  fetch from an entry an agent's raw `gh api` read already stored.

  Reading is safe precisely because most of the store is not readable. The
  wrapper files `gh api repos/o/r/issues/N` under `<repo>/issue/<N>/` and its
  stdout is the REST issue body; it files `gh issue view N --json …` under the
  same directory and that stdout is a projection. `read_body/2` cannot tell
  which shape a file is by name, so it **validates**: a body is served only if
  it parses as JSON and carries the resource's own `number` and API `url` — the
  two fields a projection never has. Every other doubt (a torn entry, an
  unreadable meta, a non-issue shape, an invalidated entry, a future stamp) is
  a `:miss`, and the caller fetches exactly as it would without the store. A
  failed read costs throughput, never correctness — the same fail-open this
  module's writes use.

  Freshness is a stated backstop, not a delivery guess. The daemon cannot know
  the wrapper's configured TTL. So `read_body/2` accepts an entry only within
  `@agent_read_backstop_ms` (or the caller's own tolerance, whichever is
  tighter) and only when no covering invalidation marker is newer than the
  entry's fetch stamp — the same marker test the wrapper applies. The ceiling is
  deliberately the wrapper's own 60 s freshness window: serving an entry older
  than that would hand the daemon something the agent store itself no longer
  serves. #2331's recovery defects (which previously made leaning on delivery
  retirement unsafe) have since landed on main; evaluating a longer backstop
  against measured delivery reliability is the documented follow-up, not a
  change folded into this read-direction work.

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

  # The backstop an agent-cache entry may be served to the daemon at, in
  # milliseconds, measured from the entry's own fetch stamp.
  #
  # Justification, stated rather than assumed: the wrapper's default freshness
  # window is 60 seconds and every delivery/mutation that touches the resource
  # retires the entry through this module, so an entry younger than this that
  # has not been invalidated is an agent's own recent, un-retired read of the
  # resource. That is exactly "within the window it remains valid" — the window
  # the agent store itself honours. It is deliberately NOT longer than that
  # window: serving an entry the agent store would no longer serve is exactly
  # the stale-read risk this backstop exists to bound. #2331's gap recovery has
  # since landed on main, which re-opens the question of a longer ceiling; that
  # is the documented follow-up (see the moduledoc), not a change folded into
  # this read-direction PR.
  @agent_read_backstop_ms 60_000

  # The resource types `read_body/2` will serve. Number-addressed only, and only
  # where a body's shape is unambiguous: `:issue` and `:pull_request` bodies
  # carry their own `number`/`url`, which is what validation keys on.
  # `:issue_labels` and `:branch_pull_request` are also number-addressed and also
  # file under the wrapper's `issue`/`pr` directories, but their readers expect
  # a different projection than the raw resource, so serving the raw body to
  # them would be a semantic mismatch — they stay `:miss`.
  @readable_types [:issue, :pull_request]

  # The daemon-side "reads served from the agent store" counter table. A named
  # table so it survives across readers and does not need a process;
  # `record_served_read/0` is called from poll tasks that must never block on a
  # mailbox.
  @reads_table :aiur_agent_cache_daemon_reads_served

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

  @doc """
  Serves a number-addressed resource from the agents' `gh` replay store, or
  `:miss` when no usable entry is held.

  This is the daemon's read half of the two-store sync (see the moduledoc). It
  resolves the wrapper's directory for `key` — the same join the invalidation
  writers use — and accepts the freshest entry that:

    * parses as JSON;
    * validates as the full REST resource for the key (`number` and API `url`
      match — the fields a `gh --json` projection never carries);
    * is younger than the caller's `freshness_ms` tolerance (or
      `@agent_read_backstop_ms` when none is given), was not stamped in the
      future, and is not retired by any covering `.invalidated` marker.

  Every doubt returns `:miss`. A `:miss` costs the caller the fetch it would
  have made anyway; it never raises and never serves a shape that might not be
  the resource the key names. The caller is expected to count each `{:ok, body}`
  with `record_served_read/0` — that count is the measured reduction in
  duplicate URL fetches this bridge exists to produce.

  `state_dir` is a test seam, matching the rest of this module.
  """
  @spec read_body(ResourceStore.key() | nil, keyword()) :: {:ok, term()} | :miss
  def read_body({type, _owner, _repo, _id} = key, opts) when type in @readable_types do
    case resource_dir(key, opts) do
      dir when is_binary(dir) -> first_valid_body(dir, key, opts)
      nil -> :miss
    end
  end

  def read_body(_key, _opts), do: :miss

  @doc """
  Records one daemon read served from the agent store.

  Called exactly once per `read_body/2` `{:ok, body}` that a daemon reader
  actually serves. The total is the "measured reduction" the acceptance asks for:
  every count is a duplicate URL fetch that did not happen.
  """
  @spec record_served_read() :: :ok
  def record_served_read do
    :ets.update_counter(reads_table(), :served, 1, {:served, 0})
    :ok
  rescue
    # The table can vanish between the lookup and the update (a bridge restart
    # mid-serve, a race on cold start). A measurement lost in that gap is a
    # rounding error, not a reason to fail a poll task — the same fail-open
    # `ReadCache.Metrics` uses.
    ArgumentError -> :ok
  end

  @doc "How many daemon reads have been served from the agent store so far."
  @spec daemon_served_reads() :: non_neg_integer()
  def daemon_served_reads do
    case :ets.whereis(@reads_table) do
      :undefined -> 0
      table -> :ets.lookup_element(table, :served, 2, 0)
    end
  end

  @doc false
  @spec reset_daemon_served_reads() :: :ok
  def reset_daemon_served_reads do
    case :ets.whereis(@reads_table) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end

    :ok
  end

  @doc """
  Makes sure the daemon-served-reads counter table exists.

  Called by `AgentCacheBridge`'s `init/1` so the table is owned by a long-lived
  supervised process rather than by whichever poll task happens to be the first
  caller — a table owned by a transient task would die with it, and the
  "measured reduction" this counter exists to report would reset with every
  poll. Idempotent: a second caller finds the existing table and leaves it
  alone. Counts are since the owning process started, exactly like
  `Aiur.GitHub.ReadCache.Metrics`, so a bridge restart resets the figure — a
  fresh boot, honestly labelled.
  """
  @spec ensure_daemon_reads_table() :: :ok
  def ensure_daemon_reads_table do
    case :ets.whereis(@reads_table) do
      :undefined ->
        try do
          :ets.new(@reads_table, [:named_table, :public, :set, write_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _existing ->
        :ok
    end

    :ok
  end

  # The table's stable owner is `AgentCacheBridge` (see
  # `ensure_daemon_reads_table/0`). This accessor still creates it on demand so
  # a test harness that does not boot the bridge, or a caller that races boot,
  # fails open instead of raising — `record_served_read/0` must never block or
  # crash a poll task.
  defp reads_table do
    case :ets.whereis(@reads_table) do
      :undefined ->
        ensure_daemon_reads_table()
        :ets.whereis(@reads_table)

      table ->
        table
    end
  end

  # The wrapper's two resource directories, and the store identities that resolve
  # to them. Everything else has no agent-side directory, and is deliberately not
  # invented one here: a name the wrapper does not write is a mark nothing will
  # ever read.
  #
  # `:issue_labels` and `:branch_pull_request` are keyed by a NUMBER an agent
  # reads by — the issue's own, and the ticket's — so both land on that number's
  # directories. `invalidate_key/2` then retires the sibling spelling too, which
  # is what GitHub's shared number space requires: `gh issue view 2073` and
  # `gh pr view 2073` are the same number.
  defp wrapper_kind(:pull_request), do: "pr"
  defp wrapper_kind(:issue), do: "issue"
  defp wrapper_kind(:issue_labels), do: "issue"
  defp wrapper_kind(:branch_pull_request), do: "issue"
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

  # -- daemon read of the agent store (#2413) --------------------------------

  # The freshest usable shape wins. The wrapper hashes every argument into the
  # filename, so one resource's directory can hold several shapes — a raw `gh
  # api` read, a `--jq` projection, an old paginated page. The daemon cannot
  # know which is which by name, so it sorts by fetch stamp (freshest first,
  # unreadable stamps last) and takes the first that validates.
  defp first_valid_body(dir, key, opts) do
    dir
    |> Path.join("*.body")
    |> Path.wildcard()
    |> Enum.sort_by(&shape_fetched_at/1, &>=/2)
    |> Enum.reduce_while(:miss, fn body_path, _acc ->
      case servable_shape(body_path, dir, key, opts) do
        {:ok, body} -> {:halt, {:ok, body}}
        :skip -> {:cont, :miss}
      end
    end)
  end

  defp servable_shape(body_path, entry_dir, {type, owner, repo, id}, opts) do
    meta_path = String.replace_suffix(body_path, ".body", ".meta")

    with {:ok, fetched_at_s} <- read_fetched_at(meta_path),
         true <- fresh?(fetched_at_s, opts),
         false <- retired?(fetched_at_s, entry_dir, opts),
         {:ok, bytes} <- read_body_bytes(body_path),
         {:ok, decoded} <- Jason.decode(bytes),
         true <- valid_shape?(type, owner, repo, id, decoded) do
      {:ok, decoded}
    else
      _doubt -> :skip
    end
  end

  # Line 1 of the meta is the entry's fetched-at stamp (epoch seconds); line 2,
  # when present, is the response ETag the wrapper stored for a later conditional
  # re-read. Only line 1 decides whether this entry may be served.
  defp read_fetched_at(meta_path) do
    with {:ok, contents} <- File.read(meta_path),
         {:ok, line} <- first_meta_line(contents),
         {:ok, stamp} <- stamp_from(line) do
      {:ok, stamp}
    else
      _unusable -> :error
    end
  end

  # Line 1 of the meta is the entry's fetched-at stamp (epoch seconds); line 2,
  # when present, is the response ETag the wrapper stored for a later conditional
  # re-read. Only line 1 decides whether this entry may be served.
  defp first_meta_line(contents) do
    case contents |> String.split("\n") |> List.first() |> String.trim() do
      "" -> :error
      line -> {:ok, line}
    end
  end

  defp stamp_from(line) do
    case Integer.parse(line) do
      {stamp, ""} when stamp >= 0 -> {:ok, stamp}
      _unparseable -> :error
    end
  end

  defp fresh?(fetched_at_s, opts) do
    now = System.system_time(:second)
    age_ms = (now - fetched_at_s) * 1000

    fetched_at_s <= now and age_ms <= read_window_ms(opts)
  end

  # The caller's own tolerance wins when it is stated and tighter; the backstop
  # is the ceiling either way. A nil or non-positive caller tolerance (a caller
  # that said nothing) falls back to the backstop alone.
  defp read_window_ms(opts) do
    case Keyword.get(opts, :freshness_ms) do
      ms when is_integer(ms) and ms > 0 -> min(ms, @agent_read_backstop_ms)
      _unsaid -> @agent_read_backstop_ms
    end
  end

  # The same marker test the wrapper applies in `cache_lookup`, against the same
  # files it reads: a marker newer than the entry's fetch stamp retires it. The
  # root marker covers every repo, the repo marker covers every entry in it, and
  # the entry marker covers this resource's own shapes.
  defp retired?(fetched_at_s, entry_dir, opts) do
    root = root(opts)
    repo_dir = entry_dir |> Path.dirname() |> Path.dirname()

    [
      Path.join(root, ".invalidated"),
      Path.join(repo_dir, ".invalidated"),
      Path.join(entry_dir, ".invalidated")
    ]
    |> Enum.any?(fn path -> marker_at(path) >= fetched_at_s end)
  end

  defp marker_at(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {value, ""} -> value
          _unparseable -> 0
        end

      _unreadable ->
        0
    end
  end

  defp read_body_bytes(path) do
    case File.read(path) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 -> {:ok, bytes}
      _unreadable -> :error
    end
  end

  # A body is the full REST resource only when it carries the resource's own
  # identity: `number` equal to the key's id and the API `url` for exactly this
  # resource. A `gh --json` projection (`{"body": …}`, `{"title": …}`) has
  # neither; a `--jq` selection of the whole object has both, which is fine —
  # it is the same object. `state` is required because a real issue or pull
  # request always has one, and requiring it is what keeps a non-resource JSON
  # object (a rate-limit body, a generic `{}`) from being served.
  defp valid_shape?(:issue, owner, repo, id, decoded) when is_map(decoded) do
    Map.get(decoded, "number") == number(id) and
      api_url_matches?(Map.get(decoded, "url"), owner, repo, "issues", id) and
      is_binary(Map.get(decoded, "state"))
  end

  defp valid_shape?(:pull_request, owner, repo, id, decoded) when is_map(decoded) do
    Map.get(decoded, "number") == number(id) and
      api_url_matches?(Map.get(decoded, "url"), owner, repo, "pulls", id) and
      is_binary(Map.get(decoded, "state"))
  end

  defp valid_shape?(_type, _owner, _repo, _id, _decoded), do: false

  defp number(id) do
    case Integer.parse(to_string(id)) do
      {value, ""} -> value
      _unparseable -> nil
    end
  end

  # GitHub's API `url` uses the repository's canonical casing, while the key is
  # down-cased, so the path comparison is case-insensitive.
  defp api_url_matches?("https://api.github.com/repos/" <> rest, owner, repo, kind, id) do
    String.downcase(rest) == "#{owner}/#{repo}/#{kind}/#{id}"
  end

  defp api_url_matches?(_url, _owner, _repo, _kind, _id), do: false

  # Sorting key: the fetch stamp for a readable meta, `nil` for anything else so
  # an unreadable shape sorts last and is never chosen over a readable one.
  defp shape_fetched_at(body_path) do
    case read_fetched_at(String.replace_suffix(body_path, ".body", ".meta")) do
      {:ok, fetched_at_s} -> fetched_at_s
      :error -> nil
    end
  end
end
