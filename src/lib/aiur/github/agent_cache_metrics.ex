defmodule Aiur.GitHub.AgentCacheMetrics do
  @moduledoc """
  Reads the agent-side `gh` replay cache's durable effectiveness counters.

  Each issue workspace owns an active `agent-cache.tsv` plus bounded rotated
  archives. One dashboard-scoped sampler combines those daemon-host files over
  a rolling 24-hour window and retains the latest snapshot for every viewer. It
  deliberately fails open: one unreadable source or malformed row does not hide
  valid measurements from the other workspaces, but the snapshot marks that
  coverage as partial.

  Only `hit` and `miss` form the effectiveness denominator. `store` follows a
  miss, while `coalesced` records simultaneous-request suppression rather than
  reuse of an answer that was already present.
  """

  use GenServer

  alias Aiur.Config
  alias Aiur.Workspace.Layout

  @window_seconds 24 * 60 * 60
  @default_interval_ms 30_000
  @events ~w(hit miss store coalesced)
  @miss_reasons %{
    "absent" => :absent,
    "expired" => :expired,
    "invalidated" => :invalidated,
    "bypassed" => :bypassed,
    "clock-skewed" => :"clock-skewed",
    "corrupt" => :corrupt
  }

  @type snapshot :: %{
          available?: boolean(),
          measured?: boolean(),
          partial?: boolean(),
          hits: non_neg_integer(),
          misses: non_neg_integer(),
          stores: non_neg_integer(),
          coalesced: non_neg_integer(),
          sample_size: non_neg_integer(),
          hit_ratio: float() | nil,
          miss_reasons: %{optional(atom()) => non_neg_integer()},
          sources_read: non_neg_integer(),
          skipped_sources: non_neg_integer(),
          malformed_rows: non_neg_integer(),
          window_started_at: DateTime.t(),
          window_ended_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Returns the sampler's latest snapshot without touching the filesystem."
  @spec snapshot() :: snapshot()
  def snapshot, do: cached_snapshot(__MODULE__)

  @doc "Reads a snapshot directly. Options are a deterministic test seam."
  @spec snapshot(keyword()) :: snapshot()
  def snapshot(opts) when is_list(opts), do: read_snapshot(opts)

  @doc "Returns a named or private sampler's latest snapshot."
  @spec cached_snapshot(GenServer.server()) :: snapshot()
  def cached_snapshot(server) do
    GenServer.call(server, :snapshot)
  catch
    :exit, _reason -> unavailable_snapshot(DateTime.utc_now())
  end

  @doc "Forces one sampler refresh."
  @spec sample(GenServer.server()) :: :ok
  def sample(server \\ __MODULE__) do
    GenServer.call(server, :sample)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    state = %{
      snapshot: read_snapshot(opts),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      reader_opts: Keyword.drop(opts, [:interval_ms, :name])
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  def handle_call(:sample, _from, state) do
    {:reply, :ok, refresh(state)}
  end

  @impl true
  def handle_info(:sample, state) do
    state = refresh(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp read_snapshot(opts) do
    now = Keyword.get(opts, :clock, &DateTime.utc_now/0).()
    started_unix = DateTime.to_unix(now) - @window_seconds
    now_unix = DateTime.to_unix(now)
    paths = Keyword.get_lazy(opts, :paths, fn -> default_paths(Keyword.get_lazy(opts, :workspace_root, &Config.workspace_root/0)) end)
    read_fun = Keyword.get(opts, :read_fun, &File.read/1)
    stat_fun = Keyword.get(opts, :stat_fun, &File.stat(&1, time: :posix))

    counts = Enum.reduce(paths, empty_counts(), &read_source(&1, &2, read_fun, stat_fun, started_unix, now_unix))

    sample_size = counts.hits + counts.misses

    counts
    |> Map.put(:available?, counts.sources_read > 0)
    |> Map.put(:measured?, sample_size > 0)
    |> Map.put(:partial?, counts.skipped_sources > 0 or counts.malformed_rows > 0)
    |> Map.put(:sample_size, sample_size)
    |> Map.put(:hit_ratio, if(sample_size > 0, do: counts.hits / sample_size, else: nil))
    |> Map.put(:window_started_at, DateTime.from_unix!(started_unix))
    |> Map.put(:window_ended_at, now)
  rescue
    _unavailable -> unavailable_snapshot(DateTime.utc_now())
  catch
    _kind, _reason -> unavailable_snapshot(DateTime.utc_now())
  end

  defp refresh(state), do: %{state | snapshot: read_snapshot(state.reader_opts)}

  defp schedule(%{interval_ms: interval}) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :sample, interval)

  defp schedule(_state), do: :ok

  defp read_source(path, counts, read_fun, stat_fun, started_unix, now_unix) do
    case stat_fun.(path) do
      {:ok, %{mtime: modified_at}} when is_integer(modified_at) and modified_at < started_unix ->
        %{counts | sources_read: counts.sources_read + 1}

      {:ok, _stat} ->
        read_rows(path, counts, read_fun, started_unix, now_unix)

      _unreadable ->
        %{counts | skipped_sources: counts.skipped_sources + 1}
    end
  rescue
    _unavailable -> %{counts | skipped_sources: counts.skipped_sources + 1}
  catch
    _kind, _reason -> %{counts | skipped_sources: counts.skipped_sources + 1}
  end

  defp read_rows(path, counts, read_fun, started_unix, now_unix) do
    case read_fun.(path) do
      {:ok, contents} when is_binary(contents) ->
        contents
        |> String.splitter("\n")
        |> Enum.reduce(%{counts | sources_read: counts.sources_read + 1}, fn line, acc ->
          count_line(acc, line, started_unix, now_unix)
        end)

      _unreadable ->
        %{counts | skipped_sources: counts.skipped_sources + 1}
    end
  end

  defp count_line(counts, "", _started_unix, _now_unix), do: counts

  defp count_line(counts, line, started_unix, now_unix) do
    case parse_line(line) do
      {:ok, unix, event, reason} ->
        if unix >= started_unix and unix <= now_unix, do: increment(counts, event, reason), else: counts

      :error ->
        %{counts | malformed_rows: counts.malformed_rows + 1}
    end
  end

  defp parse_line(line) do
    case String.split(line, "\t") do
      [unix, consumer, event, kind, id] -> parse_columns(unix, consumer, event, kind, id, nil)
      [unix, consumer, "miss" = event, kind, id, reason] -> parse_columns(unix, consumer, event, kind, id, reason)
      _other -> :error
    end
  end

  defp parse_columns(unix, consumer, event, kind, id, reason) do
    with {unix, ""} <- Integer.parse(unix),
         true <- unix >= 0,
         true <- consumer != "" and kind != "" and id != "",
         true <- event in @events,
         true <- is_nil(reason) or Map.has_key?(@miss_reasons, reason) do
      {:ok, unix, event, if(reason, do: Map.fetch!(@miss_reasons, reason))}
    else
      _invalid -> :error
    end
  end

  defp increment(counts, "hit", _reason), do: %{counts | hits: counts.hits + 1}

  defp increment(counts, "miss", reason) do
    reason = reason || :unknown

    %{counts | misses: counts.misses + 1, miss_reasons: Map.update(counts.miss_reasons, reason, 1, &(&1 + 1))}
  end

  defp increment(counts, "store", _reason), do: %{counts | stores: counts.stores + 1}
  defp increment(counts, "coalesced", _reason), do: %{counts | coalesced: counts.coalesced + 1}

  defp empty_counts do
    %{
      hits: 0,
      misses: 0,
      stores: 0,
      coalesced: 0,
      miss_reasons: %{},
      sources_read: 0,
      skipped_sources: 0,
      malformed_rows: 0
    }
  end

  defp unavailable_snapshot(now) do
    empty_counts()
    |> Map.merge(%{
      available?: false,
      measured?: false,
      partial?: false,
      sample_size: 0,
      hit_ratio: nil,
      window_started_at: DateTime.add(now, -@window_seconds, :second),
      window_ended_at: now
    })
  end

  # Mirrors `Aiur.GitHub.Quota`'s agent-shell request-log discovery. The probe
  # creates the repository-specific workspace prefix without assuming whether
  # the active tracker contributes a repo segment to the layout.
  defp default_paths(workspace_root) do
    workspace_pattern =
      workspace_root
      |> Path.expand()
      |> Layout.issue_workspace_path("__github_agent_cache_probe__")
      |> Path.dirname()

    pattern = Path.join(workspace_pattern, "*/.aiur-runtime/github-quota/agent-cache.tsv*")

    pattern
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(fn path ->
      basename = Path.basename(path)
      basename == "agent-cache.tsv" or String.starts_with?(basename, "agent-cache.tsv.")
    end)
  rescue
    _unavailable -> []
  end
end
