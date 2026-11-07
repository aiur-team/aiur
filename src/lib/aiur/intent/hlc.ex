defmodule Aiur.Intent.Hlc do
  @moduledoc """
  Persisted hybrid logical clock. The persisted value is a floor: it is written (fsync)
  before it is returned, and `tick/1` only adopts the wall clock when it is ahead of it, so a
  wall clock set back never moves the clock backwards.
  """
  use GenServer

  alias Aiur.Intent.{Dir, Store}

  @max_counter 2_147_483_647
  @hold_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec tick(GenServer.server()) :: {:ok, {integer(), integer()}} | {:error, :hlc_counter_overflow | term()}
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @spec observe(GenServer.server(), {integer(), integer()}) :: :ok | :held | {:error, term()}
  def observe(server \\ __MODULE__, remote), do: GenServer.call(server, {:observe, remote})

  @impl true
  def init(opts) do
    now_fun = Keyword.get(opts, :now_fun, fn -> System.os_time(:millisecond) end)
    dir = Keyword.get_lazy(opts, :dir, &Dir.path/0)
    File.mkdir_p!(dir)
    File.chmod(dir, 0o700)
    path = Path.join(dir, "hlc.json")
    {:ok, %{now_fun: now_fun, path: path, dir: dir, hlc: load(path, dir)}}
  end

  @impl true
  def handle_call(:tick, _from, %{hlc: {w, n}} = s) do
    now = s.now_fun.()
    next = if now > w, do: {now, 0}, else: {w, n + 1}
    commit(s, next)
  end

  def handle_call({:observe, {rw, rn}}, _from, %{hlc: {w, n}} = s) do
    now = s.now_fun.()

    if rw > now + @hold_ms do
      {:reply, :held, s}
    else
      wall = Enum.max([now, w, rw])
      counter = Enum.max([if(wall == w, do: n, else: -1), if(wall == rw, do: rn, else: -1)]) + 1
      commit_observe(s, {wall, counter})
    end
  end

  defp commit(s, {_, n} = next) do
    if n > @max_counter do
      {:reply, {:error, :hlc_counter_overflow}, s}
    else
      case persist(s.path, next) do
        :ok -> {:reply, {:ok, next}, %{s | hlc: next}}
        {:error, reason} -> {:reply, {:error, reason}, s}
      end
    end
  end

  defp commit_observe(s, {_, n}) when n > @max_counter, do: {:reply, {:error, :hlc_counter_overflow}, s}

  defp commit_observe(s, next) do
    case persist(s.path, next) do
      :ok -> {:reply, :ok, %{s | hlc: next}}
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  defp persist(path, {w, n}) do
    Aiur.Fs.atomic_write(path, Jason.encode!(%{"version" => 1, "wall_ms" => w, "counter" => n}), fsync: true, mode: 0o600)
  end

  defp load(path, dir) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"wall_ms" => w, "counter" => n}} when is_integer(w) and is_integer(n) -> {w, n}
          _ -> recover(path, dir)
        end

      {:error, :enoent} ->
        {0, 0}

      {:error, _} ->
        recover(path, dir)
    end
  end

  defp recover(path, dir) do
    Aiur.Fs.quarantine(path)

    Store.own_max_hlc(dir) || {0, 0}
  end
end
