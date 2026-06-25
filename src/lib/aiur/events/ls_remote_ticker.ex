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

  alias Aiur.Alerts
  alias Aiur.Events.{GithubKeys, Publisher}
  alias Aiur.Git
  alias Aiur.GitHub.Connectivity

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
      # Resolves a commit subject for `{repo, sha}` and returns the
      # `commits` field used in the published payload. Tests inject a
      # no-op (`fn _, _ -> [] end`) so `gh api` isn't shelled out for
      # fake SHAs; production uses `&default_fetch_commits/2`, which
      # shells out to `gh` with a 2s timeout.
      commits_fun: Keyword.get(opts, :commits_fun, &default_fetch_commits/2),
      publisher: Keyword.get(opts, :publisher),
      repo: Keyword.get(opts, :repo),
      refs: %{},
      bootstrapped?: false,
      # Streak state for the connectivity escalation policy (#617): a
      # sustained DNS/auth break raises a loud operator blocker instead of
      # only Logger.debug-ing forever.
      connectivity: %{},
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

  # The shell-out and Publisher.publish are wrapped to keep the
  # GenServer alive across transport hiccups and rare upstream raises.
  # Error paths intentionally leave `bootstrapped?` untouched: until a
  # successful poll records a real ref baseline, the ticker stays in
  # bootstrap mode. Marking bootstrapped on an error with an empty
  # refs cache would make the next successful tick treat every
  # existing ticket branch as a brand-new push and fan-out a phantom
  # auto-resume for every paused blockee. A push that lands between a
  # transient error and the next success is lost, but the GitHub
  # firehose covers that window as the second detection source.
  defp run_tick(state) do
    case state.ls_remote_fun.(state.remote, [state.ref_pattern]) do
      {:ok, refs} when is_map(refs) ->
        state
        |> note_connectivity_success()
        |> fold_refs(refs)

      {:error, reason} ->
        Logger.debug("LsRemoteTicker poll failed: #{inspect(reason)}")
        note_connectivity_failure(state, Connectivity.classify_ls_remote(reason))

      other ->
        Logger.warning("LsRemoteTicker unexpected ls_remote result: #{inspect(other)}")
        state
    end
  rescue
    error ->
      Logger.warning("LsRemoteTicker tick raised: #{Exception.message(error)} (#{inspect(error.__struct__)})")

      state
  catch
    kind, reason ->
      Logger.warning("LsRemoteTicker tick caught #{kind}: #{inspect(reason)}")
      state
  end

  defp note_connectivity_success(state) do
    %{state | connectivity: Connectivity.note_success(state.connectivity, :ls_remote)}
  end

  # Records a classified ls-remote failure and emits a single operator-visible
  # blocker once a sustained DNS/auth streak crosses the escalation threshold.
  defp note_connectivity_failure(state, classification) do
    {streaks, alerts} =
      Connectivity.note_failure(state.connectivity, :ls_remote, classification)

    repo = state.repo || resolve_repo()

    Enum.each(alerts, fn alert ->
      message = Connectivity.alert_message(alert, repo: repo)

      Alerts.emit_custom("system.github.connectivity_lost", message,
        reason: message,
        needs_attention: true,
        severity: "warning"
      )
    end)

    %{state | connectivity: streaks}
  end

  defp fold_refs(state, current_refs) do
    repo = state.repo || resolve_repo()

    if state.bootstrapped? do
      Enum.each(current_refs, &maybe_publish_change(state, &1, repo))
      %{state | refs: current_refs}
    else
      # First successful tick: log so an operator can tell the ticker
      # is alive AND see the ref baseline it locked in. Silent ticker
      # is indistinguishable from a dead one in production, which
      # masked the first --test3 regression hunt.
      Logger.info("aiur_perf ls_remote_ticker phase=bootstrap_done refs=#{map_size(current_refs)} remote=#{state.remote} pattern=#{state.ref_pattern}")

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
    case GithubKeys.ref_to_topic(ref) do
      {:ticket, id, topic} ->
        Logger.info("aiur_perf ls_remote_ticker phase=publish_push ref=#{ref} sha=#{sha} topic=#{topic} ticket=#{id}")

        payload = %{
          ref: ref,
          sha: sha,
          actor: nil,
          commits: state.commits_fun.(repo, sha),
          repo: repo
        }

        publish_opts = build_publish_opts(repo, ref, sha, issue_number: id)
        do_publish(state, topic, payload, publish_opts)

      {:system, topic} ->
        Logger.info("aiur_perf ls_remote_ticker phase=publish_push ref=#{ref} sha=#{sha} topic=#{topic}")

        payload = %{
          ref: ref,
          sha: sha,
          actor: nil,
          commits: state.commits_fun.(repo, sha),
          repo: repo
        }

        do_publish(state, topic, payload, build_publish_opts(repo, ref, sha))

      nil ->
        :ignore
    end
  end

  # `git ls-remote` returns only `{ref, sha}` — no commit subject. The
  # renderer falls back to a bare "pushed" with no quoted message when
  # `commits` is empty, which is the common UX complaint after this
  # detector wins the (repo, ref, sha) dedup race against the GitHub
  # firehose (firehose carries commit subjects from the PushEvent
  # payload). Enriching synchronously here so the dedup-winning emit
  # already carries the subject. Bounded gh api call with a 2s timeout;
  # failure falls back to empty commits (no regression vs the original
  # path). Output shape matches
  # `Aiur.Events.GithubFirehose.translate/2`'s PushEvent payload so the
  # renderer side reads both sources uniformly.
  defp default_fetch_commits(repo, sha)
       when is_binary(repo) and repo != "" and is_binary(sha) and sha != "" do
    case gh_commit_subject(repo, sha) do
      {:ok, subject} when is_binary(subject) and subject != "" ->
        [%{"message" => subject, "sha" => sha}]

      _ ->
        []
    end
  end

  defp default_fetch_commits(_repo, _sha), do: []

  defp gh_commit_subject(repo, sha) do
    task =
      Task.async(fn ->
        System.cmd(
          "gh",
          ["api", "repos/#{repo}/commits/#{sha}", "--jq", ".commit.message"],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        # gh returns the full commit message; the first line is the subject.
        subject =
          output
          |> String.split("\n", parts: 2)
          |> List.first()
          |> Kernel.||("")
          |> String.trim()

        {:ok, subject}

      {:ok, {output, _nonzero}} ->
        Logger.debug("LsRemoteTicker gh commit lookup failed sha=#{sha}: #{String.trim(output)}")
        :error

      nil ->
        Logger.debug("LsRemoteTicker gh commit lookup timed out sha=#{sha}")
        :error

      other ->
        Logger.debug("LsRemoteTicker gh commit lookup raised: #{inspect(other)}")
        :error
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

  defp build_publish_opts(repo, ref, sha, extra),
    do: GithubKeys.put_push_dedup_key(extra, repo, ref, sha)

  defp do_publish(%{publisher: nil}, topic, payload, opts) do
    Publisher.publish(topic, payload, opts)
  end

  defp do_publish(%{publisher: fun}, topic, payload, opts) when is_function(fun, 3) do
    fun.(topic, payload, opts)
  end

  defp default_ls_remote(remote, refs) do
    Git.ls_remote(remote, refs)
  end

  # `Aiur.Tracker.project_identity/0` is `String.t() | nil` by spec
  # and returns `nil` cleanly when no adapter is loaded. When `nil`,
  # `build_publish_opts/4` simply omits `dedup_key:` — the publish
  # still goes through, only cross-source dedup is sacrificed for
  # that tick.
  defp resolve_repo, do: Aiur.Tracker.project_identity()
end
