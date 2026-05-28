defmodule Aiur.Events.LsRemoteTicker do
  @moduledoc """
  Polls `git ls-remote --heads origin 'refs/heads/aiur/*'` every
  `interval_ms` (default 30s) and publishes `ticket.<id>.branch.push`
  whenever a previously-known SHA changes for a ticket's branch.

  Why this exists: the GitHub `/repos/{owner}/{repo}/events` firehose
  is unreliable for PushEvents at low traffic — events can be paged
  past, batched, or simply omitted. Production observation: a real
  push of `aiur/99` followed by an immediate PR open returned ONLY the
  PullRequestEvent in the firehose poll; the PushEvent was never
  surfaced. Blockee subscribers to `ticket.99.branch.push` never woke
  up.

  The ls-remote ticker provides a parallel push detector that runs on
  a fixed cadence. The `Aiur.Events.Publisher.publish/3` dedup table
  uses `(repo, ref, sha)` as the key, so when both firehose and
  ls-remote see the same push only the first one through publishes —
  the other is silently dropped.

  ## Bootstrap

  The first tick after start has an empty cache. To avoid republishing
  every existing ticket branch's current SHA as a phantom "push", the
  first tick records SHAs without publishing. From the second tick
  onward, both **changed SHAs on known refs** and **brand-new refs**
  publish a push event — a new ref only appears between two polls
  when an agent has actually pushed it for the first time.
  """

  use GenServer

  require Logger

  alias Aiur.Events.Publisher
  alias Aiur.Git

  @default_interval_ms 30_000
  @default_remote "origin"
  @default_ref_pattern "refs/heads/aiur/*"

  @doc """
  Start the ticker. Accepts:

    * `:interval_ms` — tick period in milliseconds (default 30s).
    * `:remote` — `git` remote name or URL (default `"origin"`).
    * `:ref_pattern` — `ls-remote` ref pattern (default `"refs/heads/aiur/*"`).
    * `:ls_remote_fun` — `(remote, refs) -> {:ok, map} | {:error, term}`
      for tests that want to bypass `git`.
    * `:publisher` — `(topic, payload, opts) -> term` for tests that
      want to capture publishes instead of going through Exchange.
    * `:repo` — `"owner/repo"` used for the dedup key. When `nil` (the
      production default), the ticker resolves it via
      `Aiur.Tracker.project_identity/0` on every tick so config edits
      are picked up without a restart.
    * `:start_paused?` — when `true`, the first tick is not scheduled.
      Tests drive `:tick` manually.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      remote: Keyword.get(opts, :remote, @default_remote),
      ref_pattern: Keyword.get(opts, :ref_pattern, @default_ref_pattern),
      ls_remote_fun: Keyword.get(opts, :ls_remote_fun, &default_ls_remote/2),
      publisher: Keyword.get(opts, :publisher),
      repo: Keyword.get(opts, :repo),
      refs: %{},
      bootstrapped?: false,
      start_paused?: Keyword.get(opts, :start_paused?, false)
    }

    unless state.start_paused?, do: schedule_tick(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = run_tick(state)
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  defp schedule_tick(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp run_tick(state) do
    case state.ls_remote_fun.(state.remote, [state.ref_pattern]) do
      {:ok, refs} when is_map(refs) ->
        fold_refs(state, refs)

      {:error, reason} ->
        Logger.debug("LsRemoteTicker poll failed: #{inspect(reason)}")
        # Mark `bootstrapped?: true` even on a failed first tick so the
        # next *successful* poll publishes for any ref it sees as new.
        # Otherwise tick 1 (error) + tick 2 (success) would silently
        # absorb every aiur/<id> push that happened during that window
        # — the agent we most want to wake up is exactly the one that
        # pushed right after a transient ls-remote failure.
        %{state | bootstrapped?: true}
    end
  end

  defp fold_refs(state, current_refs) do
    repo = state.repo || resolve_repo()

    if state.bootstrapped? do
      Enum.each(current_refs, &maybe_publish_change(state, &1, repo))
      %{state | refs: current_refs}
    else
      %{state | refs: current_refs, bootstrapped?: true}
    end
  end

  defp maybe_publish_change(state, {ref, sha}, repo) do
    if changed?(state.refs, ref, sha), do: publish_push(state, ref, sha, repo)
  end

  defp changed?(known_refs, ref, sha) do
    case Map.get(known_refs, ref) do
      ^sha -> false
      _ -> true
    end
  end

  defp publish_push(state, ref, sha, repo) do
    case ref_to_topic(ref) do
      {:ticket, id, topic} ->
        payload = %{ref: ref, sha: sha, actor: nil, commits: [], repo: repo}
        publish_opts = build_publish_opts(repo, ref, sha, issue_number: id)
        do_publish(state, topic, payload, publish_opts)

      {:system, topic} ->
        payload = %{ref: ref, sha: sha, actor: nil, commits: [], repo: repo}
        do_publish(state, topic, payload, build_publish_opts(repo, ref, sha))

      nil ->
        :ignore
    end
  end

  # Only attach the `(repo, ref, sha)` dedup_key when the repo is a
  # non-empty string. `Aiur.Events.Publisher.deduped?/1` matches on
  # `{repo, ref, sha}` with three binaries; a `nil` repo (e.g.
  # `Aiur.Tracker.project_identity/0` returning nil during a config
  # gap) would have raised FunctionClauseError before the catch-all
  # was added to Publisher. Suppressing the key here keeps the
  # contract clean.
  defp build_publish_opts(repo, ref, sha, extra \\ [])

  defp build_publish_opts(repo, ref, sha, extra) when is_binary(repo) and repo != "" do
    Keyword.put(extra, :dedup_key, {repo, ref, sha})
  end

  defp build_publish_opts(_repo, _ref, _sha, extra), do: extra

  defp do_publish(%{publisher: nil}, topic, payload, opts) do
    Publisher.publish(topic, payload, opts)
  end

  defp do_publish(%{publisher: fun}, topic, payload, opts) when is_function(fun, 3) do
    fun.(topic, payload, opts)
  end

  defp do_publish(%{publisher: {mod, fun}}, topic, payload, opts)
       when is_atom(mod) and is_atom(fun) do
    apply(mod, fun, [topic, payload, opts])
  end

  defp ref_to_topic(ref) when is_binary(ref) do
    case Regex.run(~r{\Arefs/heads/aiur/(\d+)\z}, ref) do
      [_, id] ->
        {:ticket, id, "ticket.#{id}.branch.push"}

      _ ->
        case Regex.run(~r{\Arefs/heads/([^/]+)\z}, ref) do
          [_, branch] -> {:system, "system.#{branch}.branch.push"}
          _ -> nil
        end
    end
  end

  defp ref_to_topic(_), do: nil

  defp default_ls_remote(remote, refs) do
    Git.ls_remote(remote, refs)
  end

  # Best-effort: resolve repo name (e.g. "owner/repo") via the
  # configured Tracker adapter. Returns `nil` if the call fails — the
  # dedup_key just becomes `{nil, ref, sha}` and Publisher still
  # dedupes its own re-emits. The firehose-vs-ls-remote dedup loses
  # cross-source coverage in that window, which is acceptable for the
  # rare repo-misconfig case.
  defp resolve_repo do
    Aiur.Tracker.project_identity()
  rescue
    _ -> nil
  end
end
