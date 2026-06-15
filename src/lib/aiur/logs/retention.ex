defmodule Aiur.Logs.Retention do
  @moduledoc """
  Periodically bounds the unified log home (`~/.aiur/logs`) to
  `max_log_history_mb` (`.aiurconfig`, default 1000 MB).

  Every `interval_ms` (default 5 min) it sums the size of every session
  directory directly under the root and, while the total exceeds the
  cap, deletes the oldest session (by mtime) until the total is back
  under it. The active session is never deleted, so a single run that
  alone exceeds the cap is kept (and a warning logged) rather than
  self-destructing mid-session.

  Runs regardless of `--debug`/`--test` flags — it is the disk-safety
  mechanism that replaces the rotation `Aiur.LogFile` deliberately
  dropped.
  """

  use GenServer

  require Logger

  alias Aiur.Config
  alias Aiur.Config.Paths

  @default_interval_ms 5 * 60 * 1000
  @default_cap_mb 1000
  @bytes_per_mb 1_048_576

  @doc """
  Start the sweep. Accepts (all optional, defaults shown):

    * `:interval_ms` — sweep period (default 5 min).
    * `:root` — log home to bound (default `~/.aiur/logs`).
    * `:cap_mb_fun` — `(-> pos_integer)` cap source (default reads config).
    * `:current_session_fun` — `(-> path | nil)` session never to delete.
    * `:start_paused?` — skip the first scheduled tick (tests drive `sweep/1`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Run one sweep synchronously and return its summary. For tests/ops."
  @spec sweep(GenServer.server()) :: map()
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      root: Keyword.get(opts, :root, default_root()),
      cap_mb_fun: Keyword.get(opts, :cap_mb_fun, &resolve_cap_mb/0),
      current_session_fun: Keyword.get(opts, :current_session_fun, &current_session_dir/0),
      start_paused?: Keyword.get(opts, :start_paused?, false)
    }

    unless state.start_paused?, do: schedule_tick(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_sweep(state)
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:sweep, _from, state) do
    {:reply, run_sweep(state), state}
  end

  defp schedule_tick(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :tick, interval_ms)
  end

  # Wrapped so a transient FS hiccup never takes the GenServer down — a
  # crashed retention sweep would silently stop bounding the disk.
  defp run_sweep(state) do
    cap_bytes = state.cap_mb_fun.() * @bytes_per_mb
    current = state.current_session_fun.()
    sessions = session_dirs(state.root)
    total = Enum.reduce(sessions, 0, fn {_dir, size, _mtime}, acc -> acc + size end)

    if total > cap_bytes do
      reap(sessions, total, cap_bytes, current)
    else
      %{total_bytes: total, cap_bytes: cap_bytes, deleted: 0}
    end
  rescue
    error ->
      Logger.warning("aiur_logs_retention sweep raised: #{Exception.message(error)}")
      %{error: Exception.message(error), deleted: 0}
  end

  defp reap(sessions, total, cap_bytes, current) do
    result =
      sessions
      |> Enum.sort_by(fn {_dir, _size, mtime} -> mtime end)
      |> Enum.reduce_while(%{total_bytes: total, cap_bytes: cap_bytes, deleted: 0}, fn
        {dir, size, _mtime}, acc ->
          cond do
            acc.total_bytes <= cap_bytes ->
              {:halt, acc}

            dir == current ->
              # Never delete the active session, even if it alone is over
              # cap — skip it and keep scanning older siblings.
              {:cont, acc}

            true ->
              File.rm_rf(dir)
              Logger.info("aiur_logs_retention phase=reap dir=#{dir} freed_bytes=#{size}")
              {:cont, %{acc | total_bytes: acc.total_bytes - size, deleted: acc.deleted + 1}}
          end
      end)

    if result.total_bytes > cap_bytes do
      Logger.warning(
        "aiur_logs_retention still over cap after sweep (active session kept): " <>
          "total=#{result.total_bytes} cap=#{cap_bytes}"
      )
    end

    result
  end

  defp session_dirs(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(fn dir -> {dir, dir_size(dir), dir_mtime(dir)} end)

      _ ->
        []
    end
  end

  defp dir_size(dir) do
    Path.join(dir, "**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reduce(0, fn path, acc ->
      case File.stat(path) do
        {:ok, %{type: :regular, size: size}} -> acc + size
        _ -> acc
      end
    end)
  end

  defp dir_mtime(dir) do
    case File.stat(dir, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  defp default_root, do: Path.expand("~/.aiur/logs")

  defp resolve_cap_mb do
    Config.max_log_history_mb()
  rescue
    _ -> @default_cap_mb
  catch
    _, _ -> @default_cap_mb
  end

  # The active session is the direct child of the root that is an
  # ancestor of the live log dir (`<root>/<session>/log`). Returns nil
  # when the active logs live outside the retention root (e.g. a custom
  # `--logs-root`), in which case nothing under `~/.aiur/logs` is live.
  defp current_session_dir do
    root = default_root()
    log_dir = Paths.log_root_dir()

    if String.starts_with?(log_dir, root <> "/") do
      first = log_dir |> Path.relative_to(root) |> Path.split() |> hd()
      Path.join(root, first)
    end
  rescue
    _ -> nil
  end
end
