defmodule Aiur.ProcessReaper do
  @moduledoc """
  Central registry of agent OS processes and tmux panes, reaped through one
  chokepoint at shutdown so no agent survives an aiur exit.

  Every backend registers the OS pid / pane id it spawns as soon as the id is
  known and unregisters on its own clean teardown. Shutdown then reaps in
  kind order: `:agent` entries (REPL/headless/codex trees, chat panes) before
  opencode-session deletion, `:serve` entries (opencode-serve) after it —
  `SessionWriterRegistry.delete_all/1` needs live serves for its HTTP deletes.

  The registry is the correctness-critical kill path; the pre-existing
  per-backend reapers (`kill_repl_session`, `stop_port` tree-reap,
  `sweep_own_panes`, the aiurdev bash traps) remain as defense in depth.

  Safety properties:

    * **pid-reuse guard** — entries registered with a `:comm` meta substring
      are killed only if `/proc/<pid>/cmdline` still matches it; a recycled
      pid is skipped. Crash-path entries (whose owner died before
      unregistering) are deliberately KEPT — an orphan is exactly what this
      registry exists to kill, and the guard makes that safe.
    * **shutdown-scoped draining** — a `drain: true` reap (only from
      `Aiur.Shutdown.cleanup/1` and this server's own `terminate/2`) flips
      the registry into draining mode where new registrations are killed
      immediately, closing the "a runner task respawns an agent between
      cleanup and tree teardown" window. `Orchestrator.terminate/2`'s
      best-effort reap uses `drain: false` so a supervised orchestrator
      crash-restart never latches draining and bricks agent spawning.
    * **never raises** — per-entry kills are wrapped; one bad entry never
      stops the sweep.

  The spawn→register crash window is NOT covered here; that remains assigned
  to the `reap_workspace_agents` pgrep layer.

  A **dead BEAM** (e.g. an `:emfile` crash) can reap nothing from inside itself,
  so on each `:agent` register this module also appends the agent's os_pid/pane
  to the `AIUR_AGENT_TMPFILE` pidfile (see `record_agent_pidfile/3`). The bash
  launcher's BEAM-death watchdog reads that file to kill pane + headless agents
  after the BEAM is gone — mirroring how `AIUR_SESSION_TMPFILE` feeds the
  opencode-session cleanup trap.

  Registrations no-op when `:process_reaper_registrations` is configured
  false (test env) so unit tests never kill host processes.
  """

  use GenServer, shutdown: 30_000

  require Logger

  alias Aiur.Claude.RemoteControl

  @type kind :: :agent | :serve
  @type ref :: {:os_pid, pos_integer()} | {:pane, String.t()}

  # ------------------------------------------------------------------ API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a spawned process or pane. `ref` pids may arrive as integers or
  numeric strings (the port-metadata fields store strings); both normalize
  to integers so the default killer's `is_integer` clause matches.

  Meta:
    * `:comm` — substring expected in `/proc/<pid>/cmdline`; guards against
      pid reuse. Pane refs need no guard.
  """
  @spec register(kind(), ref() | {:os_pid, nil | String.t()}, keyword()) :: :ok
  def register(kind, ref, meta \\ []) when kind in [:agent, :serve] and is_tuple(ref),
    do: register(__MODULE__, kind, ref, meta)

  # Mixing a leading default server with a trailing default meta shifts
  # arguments on 3-arity calls, so the server-qualified form takes all four
  # args explicitly (tests pass `[]` for meta).
  @spec register(GenServer.server(), kind(), ref() | {:os_pid, nil | String.t()}, keyword()) :: :ok
  def register(server, kind, ref, meta) when kind in [:agent, :serve] do
    if registrations_enabled?() do
      case normalize_ref(ref) do
        nil -> :ok
        normalized -> safe_call(server, {:register, kind, normalized, Map.new(meta)})
      end
    else
      :ok
    end
  end

  @spec unregister(ref() | {:os_pid, nil | String.t()}) :: :ok
  def unregister(ref) when is_tuple(ref), do: unregister(__MODULE__, ref)

  @spec unregister(GenServer.server(), ref() | {:os_pid, nil | String.t()}) :: :ok
  def unregister(server, ref) do
    if registrations_enabled?() do
      case normalize_ref(ref) do
        nil -> :ok
        normalized -> safe_call(server, {:unregister, normalized})
      end
    else
      :ok
    end
  end

  @doc """
  Kill every registered entry of the given kinds and remove them. Options:

    * `:drain` — flip into draining mode (default false). Only shutdown
      chokepoints pass true.
    * `:kill_tree` / `:kill_pane` / `:cmdline_reader` — injectable for tests.
  """
  @spec reap([kind()], keyword()) :: :ok
  def reap(kinds, opts \\ []) when is_list(kinds) and is_list(opts),
    do: reap(__MODULE__, kinds, opts)

  @spec reap(GenServer.server(), [kind()], keyword()) :: :ok
  def reap(server, kinds, opts) when is_list(kinds) and is_list(opts) do
    safe_call(server, {:reap, kinds, Map.new(opts)}, 25_000)
  end

  # The reaper lives near the top of the supervision tree; callers (backends,
  # shutdown layers) must never crash because it is missing or already dead.
  defp safe_call(server, msg, timeout \\ 5_000) do
    GenServer.call(server, msg, timeout)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp registrations_enabled? do
    Application.get_env(:aiur, :process_reaper_registrations, true)
  end

  defp normalize_ref({:os_pid, nil}), do: nil
  defp normalize_ref({:os_pid, pid}) when is_integer(pid) and pid > 0, do: {:os_pid, pid}

  defp normalize_ref({:os_pid, pid}) when is_binary(pid) do
    case Integer.parse(pid) do
      {int, ""} when int > 0 -> {:os_pid, int}
      _ -> nil
    end
  end

  defp normalize_ref({:pane, pane_id}) when is_binary(pane_id) and pane_id != "", do: {:pane, pane_id}
  defp normalize_ref(_other), do: nil

  # ------------------------------------------------------------- callbacks

  @impl true
  def init(_opts) do
    # Trap exits so a supervised shutdown lands in terminate/2 — the backstop
    # reap that runs on EVERY tree teardown, including SIGTERM.
    Process.flag(:trap_exit, true)
    {:ok, %{entries: %{}, draining: false}}
  end

  @impl true
  def handle_call({:register, kind, ref, meta}, _from, %{draining: true} = state) do
    # Shutdown already swept: anything registered now would orphan. Kill it
    # on arrival (same guard rules as a sweep kill).
    Logger.info("process_reaper draining_register_kill ref=#{inspect(ref)} kind=#{kind}")
    kill_entry({ref, kind, meta}, default_killers())
    {:reply, :ok, state}
  end

  def handle_call({:register, kind, ref, meta}, _from, state) do
    record_agent_pidfile(kind, ref, meta)
    {:reply, :ok, put_in(state.entries[ref], {kind, meta})}
  end

  def handle_call({:unregister, ref}, _from, state) do
    {:reply, :ok, %{state | entries: Map.delete(state.entries, ref)}}
  end

  def handle_call({:reap, kinds, opts}, _from, state) do
    killers = Map.merge(default_killers(), Map.take(opts, [:kill_tree, :kill_pane, :cmdline_reader]))

    {to_reap, keep} =
      Enum.split_with(state.entries, fn {_ref, {kind, _meta}} -> kind in kinds end)

    Enum.each(to_reap, fn {ref, {kind, meta}} -> kill_entry({ref, kind, meta}, killers) end)

    draining = state.draining or Map.get(opts, :drain, false)
    {:reply, :ok, %{state | entries: Map.new(keep), draining: draining}}
  end

  @impl true
  def terminate(_reason, state) do
    # Last-resort sweep for every entry still registered when the tree comes
    # down. Session deletion has already happened by now on the graceful
    # paths (Shutdown.cleanup / Application.prep_stop), so killing :serve
    # entries here is correct, not premature.
    Enum.each(state.entries, fn {ref, {kind, meta}} ->
      kill_entry({ref, kind, meta}, default_killers())
    end)

    :ok
  end

  # ----------------------------------------------------- crash-reaper pidfile

  # Mirrors the `AIUR_SESSION_TMPFILE` precedent: the BEAM appends one line per
  # spawned agent so the bash launcher's BEAM-death watchdog can reap pane and
  # headless agents after the BEAM itself is gone (a dead BEAM can kill nothing).
  # Only `:agent` entries are recorded — `:serve` (opencode-serve) is handled by
  # the session tmpfile + HTTP delete path. Best-effort: a write failure must
  # never break agent registration.
  #
  # The file is append-only by design: `unregister/2` does not prune it. The
  # launcher truncates it once per run and guards every recorded pid at reap time
  # (alive + command still matches the recorded comm), so a cleanly-exited or
  # recycled pid is skipped rather than mis-killed — the same pid-reuse guarantee
  # the in-memory `cmdline_guard` gives, without the BEAM having to rewrite a file
  # on every agent teardown.
  defp record_agent_pidfile(:agent, ref, meta) do
    case System.get_env("AIUR_AGENT_TMPFILE") do
      nil -> :ok
      "" -> :ok
      path -> append_pidfile_line(path, pidfile_line(ref, meta))
    end
  end

  defp record_agent_pidfile(_kind, _ref, _meta), do: :ok

  defp pidfile_line({:os_pid, pid}, %{comm: comm}) when is_binary(comm) and comm != "",
    do: "pid #{pid} #{comm}"

  defp pidfile_line({:os_pid, pid}, _meta), do: "pid #{pid}"
  # Pane lines are recorded for diagnostics/symmetry; the launcher reaps panes via
  # `tmux kill-server`, not this pidfile, so it reads only `pid` lines.
  defp pidfile_line({:pane, pane_id}, _meta), do: "pane #{pane_id}"

  defp append_pidfile_line(path, line) do
    File.write(path, line <> "\n", [:append])
    :ok
  rescue
    error ->
      Logger.warning("process_reaper pidfile_write_failed path=#{path} error=#{inspect(error)}")
      :ok
  end

  # ---------------------------------------------------------------- kills

  defp default_killers do
    %{
      kill_tree: &RemoteControl.graceful_kill_tree/1,
      kill_pane: &Aiur.Tmux.kill_pane/1,
      cmdline_reader: &read_cmdline/1
    }
  end

  defp kill_entry({{:os_pid, pid}, kind, meta}, killers) do
    case cmdline_guard(pid, meta[:comm], killers.cmdline_reader) do
      :kill ->
        killers.kill_tree.(pid)

      :skip_recycled ->
        Logger.warning("process_reaper skip_recycled_pid pid=#{pid} kind=#{kind} expected_comm=#{meta[:comm]}")

      :skip_gone ->
        :ok
    end

    :ok
  catch
    outcome, reason ->
      Logger.warning("process_reaper kill_failed pid=#{pid} caught=#{inspect({outcome, reason})}")
      :ok
  end

  defp kill_entry({{:pane, pane_id}, _kind, _meta}, killers) do
    killers.kill_pane.(pane_id)
    :ok
  catch
    outcome, reason ->
      Logger.warning("process_reaper kill_failed pane=#{pane_id} caught=#{inspect({outcome, reason})}")
      :ok
  end

  # No expected comm recorded: kill unconditionally (pre-guard behavior).
  defp cmdline_guard(_pid, nil, _reader), do: :kill

  defp cmdline_guard(pid, comm, reader) do
    case reader.(pid) do
      {:ok, cmdline} ->
        if String.contains?(cmdline, comm), do: :kill, else: :skip_recycled

      _ ->
        # /proc entry unreadable — the process is already gone.
        :skip_gone
    end
  end

  defp read_cmdline(pid) do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, contents} -> {:ok, String.replace(contents, <<0>>, " ")}
      error -> error
    end
  end
end
