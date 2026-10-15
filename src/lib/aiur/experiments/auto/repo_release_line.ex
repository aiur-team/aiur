defmodule Aiur.Experiments.Auto.RepoReleaseLine do
  @moduledoc false
  use GenServer
  require Logger
  alias Aiur.Experiments.Auto.{Creator, Line, TagReader}
  alias Aiur.Experiments.Paths

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts), do: {:ok, %{opts: opts, status: :pending, task: nil}, {:continue, :poll}}

  @impl true
  def handle_continue(:poll, state), do: handle_info(:poll, state)

  @impl true
  def handle_call(:status, _from, state), do: {:reply, %{status: state.status}, state}

  @impl true
  def handle_info(:poll, %{task: nil} = state) do
    task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fn -> poll(state.opts) end)
    {:noreply, %{state | task: task}}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish_poll(result, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state), do: finish_poll({:error, {:poll_failed, reason}}, state)

  @impl true
  def terminate(_reason, %{task: task}) do
    if task, do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp finish_poll(result, state) do
    if result != :ok and state.status != :unavailable, do: Logger.warning("automatic release line unavailable: #{inspect(result)}")
    Process.send_after(self(), :poll, 3_600_000)
    {:noreply, %{state | status: if(result == :ok, do: :available, else: :unavailable), task: nil}}
  end

  @spec poll(keyword()) :: :ok | {:error, term()}
  def poll(opts) do
    path = Keyword.get(opts, :path, Path.join(Paths.root(), "auto-release-seen.json"))
    repo = Keyword.get_lazy(opts, :repo, fn -> Aiur.RepoBase.base_path(Paths.repo()) end)
    list = Keyword.get(opts, :list, &TagReader.list/1)

    with {:ok, seen} <- Aiur.JsonStore.read(path, nil),
         {:ok, tags} <- list.(repo),
         :ok <- detect(tags, seen, repo, opts) do
      remember(path, seen, tags)
    end
  end

  defp remember(path, seen, tags) do
    updated = Enum.uniq((seen || []) ++ tags)

    if updated == seen do
      :ok
    else
      with :ok <- Aiur.Journal.ensure_directory(Path.dirname(path)), do: Aiur.Fs.atomic_write(path, Jason.encode!(updated), fsync: true, mode: 0o600)
    end
  end

  defp detect(_tags, nil, _repo, _opts), do: :ok

  defp detect(tags, seen, repo, opts) when is_list(seen) do
    config = Keyword.fetch!(opts, :config)
    date = Keyword.get(opts, :date, &TagReader.date/2)

    with {:ok, lines} <- read_lines(tags -- seen, repo, config, date) do
      lines
      |> Enum.sort_by(&DateTime.to_unix(&1.at))
      |> Enum.reduce_while(:ok, &create_line(&1, opts, &2))
    end
  end

  defp detect(_tags, _invalid, _repo, _opts), do: {:error, :invalid_seen_tags}

  defp create_line(line, opts, :ok) do
    case emit(line, opts) do
      {:ok, _result} -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp read_lines(tags, repo, config, date) do
    tags |> Enum.filter(&eligible?(&1, config)) |> Enum.reduce_while({:ok, []}, &read_line(&1, repo, date, &2))
  end

  defp read_line(tag, repo, date, {:ok, lines}) do
    case date.(repo, tag) do
      {:ok, at} -> {:cont, {:ok, [%Line{source: :repo_release, key: "auto:release:#{tag}", at: at, evidence: %{tag: tag}} | lines]}}
      error -> {:halt, error}
    end
  end

  @spec eligible?(String.t(), map()) :: boolean()
  def eligible?(tag, config) do
    pattern = config.release_tag_pattern |> Regex.escape() |> String.replace("\\*", ".*") |> String.replace("\\?", ".")

    with true <- Regex.match?(Regex.compile!("\\A#{pattern}\\z"), tag),
         {:ok, version} <- Version.parse(String.trim_leading(tag, "v")) do
      config.release_include_prereleases or version.pre == []
    else
      _invalid -> false
    end
  end

  defp emit(line, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    if DateTime.diff(now, line.at) > 14 * 86_400 do
      {:ok, :old}
    else
      Creator.create(line, Keyword.get(opts, :creator, Creator))
    end
  end
end
