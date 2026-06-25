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

  The ls-remote ticker is the only ticket-branch push detector. The
  GitHub firehose no longer publishes ticket branch pushes.

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
      publisher: Keyword.get(opts, :publisher),
      repo: Keyword.get(opts, :repo),
      refs: %{},
      bootstrapped?: false,
      # Streak state for the connectivity escalation policy (#617): a
      # sustained DNS/auth break raises a loud operator blocker instead of
      # only Logger.debug-ing forever.
      connectivity: %{},
      next_delay_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      start_paused?: Keyword.get(opts, :start_paused?, false)
    }

    unless state.start_paused?, do: schedule_tick(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = run_tick(state)
    schedule_tick(state.next_delay_ms)
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
  # transient error and the next success is lost; the next successful
  # tick resumes from the observed ref state.
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
    %{
      state
      | connectivity: Connectivity.note_success(state.connectivity, :ls_remote),
        next_delay_ms: state.interval_ms
    }
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

    delay_ms =
      classification
      |> Connectivity.backoff_ms(connectivity_streak_count(streaks), %{})
      |> normalize_backoff_ms(state)

    %{state | connectivity: streaks, next_delay_ms: delay_ms}
  end

  defp connectivity_streak_count(streaks) do
    case Map.get(streaks, :ls_remote) do
      {_classification, count} when is_integer(count) and count > 0 -> count
      _ -> 1
    end
  end

  defp normalize_backoff_ms(:escalate, _state), do: Connectivity.max_backoff_ms()

  defp normalize_backoff_ms(delay_ms, _state) when is_integer(delay_ms) and delay_ms >= 0,
    do: delay_ms

  defp normalize_backoff_ms(_delay_ms, state), do: state.interval_ms

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
          commits: [],
          repo: repo
        }

        do_publish(state, topic, payload, issue_number: id)

      {:system, topic} ->
        Logger.info("aiur_perf ls_remote_ticker phase=publish_push ref=#{ref} sha=#{sha} topic=#{topic}")

        payload = %{
          ref: ref,
          sha: sha,
          actor: nil,
          commits: [],
          repo: repo
        }

        do_publish(state, topic, payload, [])

      nil ->
        :ignore
    end
  end

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
  # and returns `nil` cleanly when no adapter is loaded. `nil` still
  # publishes; the payload just has no repo identity for renderers.
  defp resolve_repo, do: Aiur.Tracker.project_identity()
end
