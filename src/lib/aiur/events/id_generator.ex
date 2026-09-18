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

  ## Where the high-water mark lives

  The counter file is `event-id.json` in the daemon-private runtime state
  directory (`Aiur.Config.Paths.runtime_state_dir/0`), which survives a
  restart. It used to be `<repo>.event_id` in the per-launch log directory,
  which is new on every launch (#2722): every boot then took the cold-boot
  path below, and its only guard against re-issuing an earlier launch's IDs
  was the wall clock. A clock that stepped back across a restart (an RTC that
  is wrong until NTP syncs, a VM restored from a snapshot) could then re-issue
  IDs that durable consumers still hold — Decision records, the Executor wake
  cursor and journal, and subscription cursors.

  ## Recovery layers

  1. **Happy path** — read the durable counter file on boot. The file stores
     `last_id` + `reserved_through`. Resume at
     `max(reserved_through, system_time(:microsecond)) + 1`. The persisted
     block alone guarantees monotonicity, so a clock that stepped back cannot
     cause reuse; the wall clock only keeps IDs close to microsecond time
     when it is ahead. A `kill -9` between writes loses at most one batch of
     *unused* IDs (a gap in the sequence); no issued ID is ever re-issued.
  2. **Cold-boot fallback** — if the file is missing or corrupt, collect
     every durable trace of an earlier ID: the per-launch `<repo>.event_id`
     counters of every earlier launch across instances (this is also the one-time migration
     from the old location), the current launch's `IssueLog` files and the
     Executor journal. Seed at `max(disk_max, system_time(:microsecond)) +
     safety_margin`. Always runs, never "if suspicious."
  3. **Genuinely fresh install** — no trace and no counter file. Seed at
     `System.system_time(:microsecond)` + safety margin. Wall-clock, not
     monotonic_time (which resets at BEAM start).

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
  alias Aiur.Executor.StatePaths
  alias Aiur.JsonStore
  alias Aiur.LaunchStateAdoption

  @default_batch_size 50
  @cold_boot_safety_margin_us 1_000_000
  @durable_file_name "event-id.json"

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
    path = Keyword.get(opts, :path) || default_path()
    clock = Keyword.get(opts, :clock, fn -> System.system_time(:microsecond) end)
    legacy_counter_files = Keyword.get(opts, :legacy_counter_files, &legacy_counter_files/0)

    {:ok,
     %{
       current: 0,
       reserved_through: 0,
       batch_size: batch_size,
       path: path,
       persist_warning_emitted: false,
       durable?: false,
       clock: clock,
       legacy_counter_files: legacy_counter_files
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
        # entirely. The wall clock can only move the start forward: a clock
        # that stepped back never takes the counter below the reserved block.
        new_current = max(max(reserved_through, last_id), state.clock.())
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
    disk_max = max(scan_durable_event_logs_for_max_id(), legacy_counter_max(state.legacy_counter_files.()))
    wall_clock_floor = state.clock.()

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

  @doc """
  The counter file path: `event-id.json` in the durable runtime state
  directory. When that directory cannot be resolved (no launcher instance key
  or no project identity), the per-launch log directory is the only place
  left; the cold-boot scan of all launches' counters keeps IDs monotonic there
  too.
  """
  @spec default_path() :: Path.t()
  def default_path do
    case Paths.runtime_state_dir() do
      {:ok, dir} ->
        Path.join(dir, @durable_file_name)

      {:error, reason} ->
        Logger.warning(
          "IdGenerator has no runtime state directory (#{inspect(reason)}); " <>
            "using the per-launch log directory, which a restart does not keep"
        )

        legacy_path()
    end
  end

  @doc false
  @spec legacy_path() :: Path.t()
  def legacy_path, do: Path.join(Paths.log_root_dir(), legacy_file_name())

  defp legacy_file_name, do: "#{Paths.repo_name()}.event_id"

  defp legacy_counter_files do
    LaunchStateAdoption.legacy_files(legacy_file_name())
  rescue
    _ -> []
  end

  # The highest ID any earlier counter file had issued or reserved. Every
  # earlier launch left its own counter, so all of them are read, not only the
  # newest: under a clock that stepped back, the newest file by mtime need not
  # hold the highest ID.
  defp legacy_counter_max(paths) do
    Enum.reduce(paths, 0, fn path, acc ->
      case JsonStore.read(path) do
        {:ok, %{} = counter} ->
          counter
          |> Map.take(["last_id", "reserved_through"])
          |> Map.values()
          |> Enum.filter(&is_integer/1)
          |> Enum.reduce(acc, &max/2)

        _unreadable ->
          acc
      end
    end)
  end

  defp scan_durable_event_logs_for_max_id do
    # Best-effort: walk per-issue log files and the Executor journal for the
    # largest event ID ever emitted. Issue logs use `[event:*] id=<int>`;
    # executor events are newline-delimited JSON with an `id` field.
    #
    # The Executor journal no longer lives in the boot log directory: it is
    # durable per-repository state that outlives this boot, which makes it the
    # one file here that can hold an id higher than anything this boot wrote.
    # Missing it would let a fresh counter re-issue ids the journal already
    # records, so it is scanned explicitly rather than by directory listing.
    log_dir = Paths.log_root_dir()

    scan_log_directory_for_max_id(log_dir)
    |> max(scan_file_for_max_id(StatePaths.journal_path()))
  rescue
    _ -> 0
  end

  defp scan_log_directory_for_max_id(log_dir) do
    case File.ls(log_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".log"))
        |> Enum.reduce(0, fn entry, acc -> max(acc, scan_file_for_max_id(Path.join(log_dir, entry))) end)

      _unreadable ->
        0
    end
  end

  defp scan_file_for_max_id(path) do
    case File.read(path) do
      {:ok, content} ->
        ~r/(?:\[event:[a-z:]+\][^\n]*\bid=|"id"\s*:\s*)(\d+)/
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
