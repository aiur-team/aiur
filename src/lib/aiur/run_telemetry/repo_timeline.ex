defmodule Aiur.RunTelemetry.RepoTimeline do
  @moduledoc """
  Durable, privacy-safe base-branch commits, red intervals and release tags.

  Commit rows preserve the first observed rollup. Later outcomes of the current
  head append interval boundaries without rewriting that original snapshot.
  """
  use GenServer
  require Logger

  alias Aiur.Config.TrackerSettings
  alias Aiur.GitHub.{Config, Errors}
  alias Aiur.RunTelemetry.{Lifecycle, Summaries}
  alias Aiur.RunTelemetry.RepoTimeline.{GitHub, Rows}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec capture(GenServer.server()) :: :ok | {:error, term()}
  def capture(server \\ __MODULE__), do: GenServer.call(server, :capture, 120_000)

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, fn -> Path.join(Summaries.analytics_dir(), "repo-timeline.ndjson") end)

    state = %{
      path: path,
      opts: opts,
      repo: Keyword.get_lazy(opts, :repo, &Aiur.GitHub.Config.repo/0),
      branch: Keyword.get(opts, :branch),
      enabled: Keyword.get(opts, :enabled_fun, &enabled?/0),
      interval: Keyword.get(opts, :interval_ms, 3_600_000),
      retry: Keyword.get(opts, :retry_ms, 60_000),
      failure_delay: Keyword.get(opts, :retry_ms, 60_000),
      timer: nil,
      now: Keyword.get(opts, :now_fun, &DateTime.utc_now/0)
    }

    if Keyword.get(opts, :boot_capture, true), do: send(self(), :capture)
    {:ok, state}
  end

  @impl true
  def handle_call(:capture, _from, state) do
    result = collect(state)
    {:reply, result, schedule(state, result)}
  end

  @impl true
  def handle_info(:capture, state) do
    result = collect(state)
    {:noreply, schedule(state, result)}
  end

  defp schedule(state, result) do
    if state.timer, do: Process.cancel_timer(state.timer)

    {delay, failure_delay} =
      cond do
        result == :ok -> {state.interval, state.retry}
        Errors.outcome(result) == :held or result == {:error, :github_budget_broker_timeout} -> {state.retry, state.failure_delay}
        true -> {min(state.failure_delay, state.interval), min(state.failure_delay * 2, state.interval)}
      end

    %{state | timer: Process.send_after(self(), :capture, delay), failure_delay: failure_delay}
  end

  defp enabled? do
    Aiur.Config.capture_github_facts?() and TrackerSettings.tracker_kind() == "github" and is_binary(Config.token())
  end

  defp collect(state) do
    if state.enabled.(), do: collect_enabled(state), else: :ok
  rescue
    _error -> {:error, :capture_exception}
  catch
    :exit, _reason -> {:error, :capture_exit}
  end

  defp collect_enabled(state) do
    with {:ok, previous} <- read_rows(state.path),
         {:ok, commits, tags} <- GitHub.fetch(state.repo, state.branch || Aiur.Config.base_branch(), Rows.cursor(previous), state.opts),
         {:ok, rows} <- Rows.appended(previous, commits, tags, DateTime.to_iso8601(state.now.())),
         :ok <- append(state.path, rows) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("Repo timeline capture deferred: #{Lifecycle.reason_class(reason)}")
        error
    end
  end

  defp read_rows(path) do
    case File.read(path) do
      {:ok, contents} -> decode_lines(String.split(contents, "\n", trim: true))
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, rows} ->
      case Jason.decode(line) do
        {:ok, row} when is_map(row) -> {:cont, {:ok, [row | rows]}}
        _ -> {:halt, {:error, :invalid_ledger}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp append(_path, []), do: :ok

  defp append(path, rows) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Enum.map(rows, &[Jason.encode!(&1), "\n"]), [:append, :sync])
    end
  end
end
