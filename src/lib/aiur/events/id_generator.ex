defmodule Aiur.Events.IdGenerator do
  @moduledoc """
  Persistent monotonic event ID counter — restart-safe via Snowflake-style
  reserve-before-return.

  Replaces `:erlang.unique_integer([:positive, :monotonic])` for event IDs.
  The Erlang per-BEAM-process counter resets on restart, which would break
  the at-least-once cursor contract used by `Aiur.Events.SubscriptionStore`
  (a persisted `last_seen_event_id` is meaningless if the in-memory counter
  starts back at 0 on the next boot). This module gives event IDs a stable
  monotonic identity across BEAM restarts.

  ## Recovery layers

  1. **Happy path** — read `<logs-root>/<repo>.event_id` on boot. The file
     stores `last_id` + `reserved_through`. Resume at `reserved_through + 1`.
     A `kill -9` between writes loses at most one batch of *unused* IDs (a
     gap in the sequence); no issued ID is ever re-issued.
  2. **Cold-boot fallback** — if the file is missing or corrupt, scan
     existing per-issue `IssueLog` files for the max event ID emitted in
     the past, then seed at `max(disk_max, system_time(:microsecond)) +
     safety_margin`. Always runs, never "if suspicious." Cost is one
     filesystem walk per boot; benefit is provable monotonicity even after
     NTP step-backwards, leap seconds, or VM clock drift.
  3. **Genuinely fresh install** — no `IssueLog`, no counter file. Seed at
     `System.system_time(:microsecond)`. Wall-clock, not monotonic_time
     (which resets at BEAM start).

  ## Reserve-before-return (Snowflake pattern)

  On every persistence write, persist `reserved_through = last_id +
  batch_size` BEFORE issuing IDs from that block. `next_id/0` increments
  the in-memory counter without I/O until it crosses `reserved_through`,
  at which point a new reservation is persisted. Tolerates `terminate/2`
  not running on `kill -9` / VM abort.

  ## Single-node only

  Runs on the orchestrator node only. Worker SSH hosts that need to publish
  events do so via RPC to the orchestrator's `Aiur.Events.Exchange`. There
  is no multi-node ID coordination problem to solve here.
  """

  use GenServer

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @default_batch_size 50
  @cold_boot_safety_margin_us 1_000_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns the next monotonic event ID. Strictly increasing across BEAM
  restarts (within the limits of the recovery layers documented in the
  module doc).
  """
  @spec next_id(GenServer.server()) :: pos_integer()
  def next_id(server \\ __MODULE__) do
    GenServer.call(server, :next_id)
  end

  @doc """
  Returns the current counter value WITHOUT advancing it. For test
  injection (subscription_created_at_event_id snapshot at binding
  creation time) and observability.
  """
  @spec peek(GenServer.server()) :: non_neg_integer()
  def peek(server \\ __MODULE__) do
    GenServer.call(server, :peek)
  end

  @doc """
  Like `next_id/1`, but fails instead of silently degrading to an
  in-memory-only ID when persistence is unavailable. For callers (such
  as `Aiur.DecisionStore`) that must never accept a durable request
  under an ID that isn't itself backed by a durably persisted
  reservation. The generic `next_id/1` API is unchanged and remains
  fail-open for existing best-effort event sources.
  """
  @spec reserve_durable_id(GenServer.server()) :: {:ok, pos_integer()} | {:error, :not_durable}
  def reserve_durable_id(server \\ __MODULE__) do
    GenServer.call(server, :reserve_durable_id)
  end

  @impl true
  def init(opts) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    path = Keyword.get(opts, :path, default_path())

    {:ok,
     %{
       current: 0,
       reserved_through: 0,
       batch_size: batch_size,
       path: path,
       persist_warning_emitted: false,
       durable?: false
     }, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    {:noreply, load_or_seed(state)}
  end

  @impl true
  def handle_call(:next_id, _from, state) do
    next = state.current + 1

    state =
      if next > state.reserved_through do
        reserve_next_batch(%{state | current: next})
      else
        %{state | current: next}
      end

    {:reply, next, state}
  end

  def handle_call(:peek, _from, state) do
    {:reply, state.current, state}
  end

  def handle_call(:reserve_durable_id, _from, state) do
    next = state.current + 1

    if next <= state.reserved_through and state.durable? do
      {:reply, {:ok, next}, %{state | current: next}}
    else
      # Not already in a confirmed-durable block (either crossing into a new
      # batch, or the current one never durably persisted) — always retry
      # the reservation rather than failing without another attempt, so a
      # transient outage doesn't strand this the only strict caller ever has
      # forever. On failure, reply with the pre-attempt current/reserved_through
      # (no ID was actually issued, so none should be skipped) but keep
      # candidate's persist_warning_emitted so repeated failures log once,
      # not once per call.
      candidate = reserve_next_batch(%{state | current: next})

      if candidate.durable? do
        {:reply, {:ok, next}, candidate}
      else
        {:reply, {:error, :not_durable}, %{state | persist_warning_emitted: candidate.persist_warning_emitted}}
      end
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Best-effort flush of the latest counter value so a graceful shutdown
    # doesn't leave the persisted `last_id` behind the in-memory counter.
    # A non-graceful exit (:kill, VM abort) skips terminate entirely; the
    # reserve-before-return contract handles that case by ensuring
    # reserved_through was persisted ahead of issued IDs.
    _ = persist(state)
    :ok
  end

  defp load_or_seed(state) do
    case JsonStore.read(state.path) do
      {:ok, %{"last_id" => last_id, "reserved_through" => reserved_through}}
      when is_integer(last_id) and is_integer(reserved_through) ->
        # Happy path: resume past the previously-reserved block. Issuing IDs
        # from inside a partially-consumed reservation could re-issue an
        # already-issued ID after a crash, so we jump past `reserved_through`
        # entirely.
        new_current = reserved_through
        reserve_next_batch(%{state | current: new_current, reserved_through: new_current})

      {:ok, nil} ->
        cold_boot_seed(state, :missing_file)

      {:ok, _other} ->
        Logger.warning("IdGenerator: counter file at #{state.path} has unexpected shape; treating as corrupt")

        cold_boot_seed(state, :corrupt_file)

      {:error, reason} ->
        Logger.warning("IdGenerator: counter file at #{state.path} could not be read (#{inspect(reason)}); treating as corrupt")

        cold_boot_seed(state, :corrupt_file)
    end
  end

  defp cold_boot_seed(state, reason) do
    disk_max = scan_issue_log_for_max_id()
    wall_clock_floor = System.system_time(:microsecond)

    seed = max(disk_max, wall_clock_floor) + @cold_boot_safety_margin_us

    Logger.warning(
      "IdGenerator cold-boot fallback (reason: #{reason}): " <>
        "disk_max=#{disk_max} wall_clock=#{wall_clock_floor} " <>
        "seed=#{seed} (= max + #{@cold_boot_safety_margin_us}us safety margin)"
    )

    reserve_next_batch(%{state | current: seed, reserved_through: seed})
  end

  defp reserve_next_batch(state) do
    new_reserved = state.current + state.batch_size
    new_state = %{state | reserved_through: new_reserved}

    case persist(new_state) do
      :ok ->
        %{new_state | persist_warning_emitted: false, durable?: true}

      {:error, reason} ->
        warn_persist_failed(new_state, reason)
    end
  end

  defp persist(state) do
    JsonStore.write!(state.path, %{
      "last_id" => state.current,
      "reserved_through" => state.reserved_through
    })
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp warn_persist_failed(%{persist_warning_emitted: true} = state, _reason), do: %{state | durable?: false}

  defp warn_persist_failed(state, reason) do
    Logger.warning(
      "IdGenerator counter persistence failed for #{state.path}: #{reason}; " <>
        "continuing with in-memory IDs only until the path is writable. " <>
        "Restart-safe monotonicity is degraded for this counter path."
    )

    %{state | persist_warning_emitted: true, durable?: false}
  end

  defp default_path do
    Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.event_id")
  end

  defp scan_issue_log_for_max_id do
    # Best-effort: walk per-issue log files looking for the largest event ID
    # ever emitted. The marker shape this module expects is
    # `[event:*] id=<int>` somewhere in the line (introduced by U19's IssueLog
    # marker extension). Until U19 lands, this returns 0 — which is correct
    # for fresh installs and the wall-clock floor in cold-boot is what's
    # actually load-bearing in that case.
    log_dir = Paths.log_root_dir()

    case File.ls(log_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".log"))
        |> Enum.reduce(0, fn entry, acc ->
          path = Path.join(log_dir, entry)
          max(acc, scan_file_for_max_id(path))
        end)

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  defp scan_file_for_max_id(path) do
    case File.read(path) do
      {:ok, content} ->
        # Match `id=<digits>` anywhere on a line tagged `[event:*]`. Tolerates
        # both the U19 marker format and the absence of any markers (returns
        # 0 if no matches).
        ~r/\[event:[a-z:]+\][^\n]*\bid=(\d+)/
        |> Regex.scan(content, capture: :all_but_first)
        |> Enum.flat_map(& &1)
        |> Enum.map(&String.to_integer/1)
        |> Enum.max(fn -> 0 end)

      _ ->
        0
    end
  rescue
    _ -> 0
  end
end
