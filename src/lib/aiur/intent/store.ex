defmodule Aiur.Intent.Store do
  @moduledoc """
  Owns the local intent files under the intent dir: `changes.ndjson` (every known change),
  `outbox.ndjson` (own changes not yet confirmed in Postgres) and `registers.json`
  (`pull_cursor`; `registers` is MPG-405's). All access is serialised through this process.
  """
  use GenServer

  require Logger

  alias Aiur.Gateway.Identity
  alias Aiur.Intent.{Change, Dir}

  @outbox_cap 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec changes(GenServer.server()) :: [Change.t()]
  def changes(server \\ __MODULE__), do: GenServer.call(server, :changes)

  @spec outbox(GenServer.server(), pos_integer() | :all) :: [Change.t()]
  def outbox(server \\ __MODULE__, limit \\ :all), do: GenServer.call(server, {:outbox, limit})

  @spec pull_cursor(GenServer.server()) :: non_neg_integer()
  def pull_cursor(server \\ __MODULE__), do: GenServer.call(server, :pull_cursor)

  @spec skipped(GenServer.server()) :: non_neg_integer()
  def skipped(server \\ __MODULE__), do: GenServer.call(server, :skipped)

  @doc "Own change: outbox first, then cache (a crash between leaves a publishable change)."
  @spec append_local(GenServer.server(), Change.t()) :: :ok | {:error, :outbox_full | term()}
  def append_local(server \\ __MODULE__, %Change{} = c), do: GenServer.call(server, {:append_local, c})

  @doc "Pulled or directly delivered changes. Never writes the outbox. Returns the changes that were new."
  @spec append_remote(GenServer.server(), [Change.t()], keyword()) :: {:ok, [Change.t()]} | {:error, term()}
  def append_remote(server \\ __MODULE__, changes, opts \\ []), do: GenServer.call(server, {:append_remote, changes, opts})

  @spec ack_outbox(GenServer.server(), [String.t()]) :: :ok | {:error, term()}
  def ack_outbox(server \\ __MODULE__, ids), do: GenServer.call(server, {:ack_outbox, ids})

  @doc "Highest own HLC found in the cache of `dir`; used to rebuild a corrupt `hlc.json`."
  @spec own_max_hlc(Path.t()) :: {integer(), integer()} | nil
  def own_max_hlc(dir) do
    gateway = Identity.current().gateway_id

    dir
    |> Path.join("changes.ndjson")
    |> read_lines()
    |> elem(0)
    |> Enum.filter(&(&1.origin_gateway == gateway))
    |> Enum.map(&{&1.hlc_wall_ms, &1.hlc_counter})
    |> Enum.max(fn -> nil end)
  end

  @impl true
  def init(opts) do
    dir = Keyword.get_lazy(opts, :dir, &Dir.path/0)
    File.mkdir_p!(dir)
    File.chmod(dir, 0o700)
    paths = %{changes: Path.join(dir, "changes.ndjson"), outbox: Path.join(dir, "outbox.ndjson"), registers: Path.join(dir, "registers.json")}
    {changes, skipped} = read_lines(paths.changes)
    {outbox, _} = read_lines(paths.outbox)

    if skipped > 0, do: Logger.warning("intent cache: skipped #{skipped} malformed lines in changes.ndjson")

    {:ok,
     %{
       paths: paths,
       changes: changes,
       ids: MapSet.new(changes, & &1.change_id),
       outbox: outbox,
       skipped: skipped,
       cursor: read_cursor(paths.registers),
       alerted?: false
     }}
  end

  @impl true
  def handle_call(:changes, _from, s), do: {:reply, s.changes, s}
  def handle_call({:outbox, :all}, _from, s), do: {:reply, s.outbox, s}
  def handle_call({:outbox, n}, _from, s), do: {:reply, Enum.take(s.outbox, n), s}
  def handle_call(:pull_cursor, _from, s), do: {:reply, s.cursor, s}
  def handle_call(:skipped, _from, s), do: {:reply, s.skipped, s}

  def handle_call({:append_local, _c}, _from, %{outbox: o} = s) when length(o) >= @outbox_cap do
    {:reply, {:error, :outbox_full}, alert_full(s)}
  end

  def handle_call({:append_local, c}, _from, s) do
    with :ok <- append(s.paths.outbox, [c]),
         :ok <- append(s.paths.changes, [c]) do
      {:reply, :ok, %{s | outbox: s.outbox ++ [c], changes: s.changes ++ [c], ids: MapSet.put(s.ids, c.change_id)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  def handle_call({:append_remote, changes, opts}, _from, s) do
    {fresh, _} =
      Enum.reduce(changes, {[], s.ids}, fn c, {acc, ids} ->
        if MapSet.member?(ids, c.change_id), do: {acc, ids}, else: {[c | acc], MapSet.put(ids, c.change_id)}
      end)

    fresh = Enum.reverse(fresh)
    cursor = Keyword.get(opts, :cursor, s.cursor) |> max(s.cursor)

    with :ok <- append(s.paths.changes, fresh),
         :ok <- write_cursor(s.paths.registers, cursor) do
      ids = Enum.reduce(fresh, s.ids, &MapSet.put(&2, &1.change_id))
      {:reply, {:ok, fresh}, %{s | changes: s.changes ++ fresh, ids: ids, cursor: cursor}}
    else
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  def handle_call({:ack_outbox, ids}, _from, s) do
    keep = Enum.reject(s.outbox, &(&1.change_id in ids))

    case rewrite(s.paths.outbox, keep) do
      :ok -> {:reply, :ok, %{s | outbox: keep}}
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  defp alert_full(%{alerted?: true} = s), do: s

  defp alert_full(s) do
    Aiur.Alerts.emit_system("system.intent.outbox_full", message: "Shared intent outbox is full; changes are refused until it drains.", needs_attention: true, severity: "warning")
    %{s | alerted?: true}
  end

  defp append(_path, []), do: :ok

  defp append(path, changes) do
    data = Enum.map(changes, &[Jason.encode!(Change.to_json(&1)), ?\n])
    new? = not File.exists?(path)

    with {:ok, io} <- File.open(path, [:append, :binary]) do
      try do
        if new?, do: File.chmod(path, 0o600)
        with :ok <- IO.binwrite(io, data), do: :file.sync(io)
      after
        File.close(io)
      end
    end
  end

  defp rewrite(path, changes) do
    Aiur.Fs.atomic_write(path, Enum.map(changes, &[Jason.encode!(Change.to_json(&1)), ?\n]), fsync: true, mode: 0o600)
  end

  defp read_lines(path) do
    case File.read(path) do
      {:ok, body} ->
        {changes, skipped} =
          body
          |> String.split("\n", trim: true)
          |> Enum.reduce({[], 0}, &parse_line/2)

        {changes |> Enum.reverse() |> Enum.uniq_by(& &1.change_id), skipped}

      {:error, _} ->
        {[], 0}
    end
  end

  defp parse_line(line, {acc, bad}) do
    with {:ok, map} <- Jason.decode(line), {:ok, c} <- Change.from_json(map) do
      {[c | acc], bad}
    else
      _ -> {acc, bad + 1}
    end
  end

  defp read_cursor(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"pull_cursor" => n}} when is_integer(n) <- Jason.decode(body) do
      n
    else
      _ -> 0
    end
  end

  defp write_cursor(path, cursor) do
    Aiur.Fs.atomic_write(path, Jason.encode!(%{"version" => 1, "pull_cursor" => cursor, "registers" => %{}}), fsync: true, mode: 0o600)
  end
end
