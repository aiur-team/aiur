defmodule Aiur.Experiments.Auto.AiurVersionLine do
  @moduledoc false
  use GenServer
  require Logger
  alias Aiur.Experiments.Auto.{Creator, DeployLedger, Line}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts), do: {:ok, opts, {:continue, :boot}}

  @impl true
  def handle_continue(:boot, opts) do
    case evaluate(opts) do
      {:error, reason} ->
        Logger.warning("automatic version line failed: #{inspect(reason)}")
        Process.send_after(self(), :retry, 60_000)

      _ok ->
        :ok
    end

    {:noreply, opts}
  end

  @impl true
  def handle_info(:retry, opts), do: handle_continue(:boot, opts)

  @spec evaluate(keyword()) :: {:ok, term()} | :ok | {:error, term()}
  def evaluate(opts) do
    ledger = Keyword.get(opts, :ledger_opts, [])
    creator = Keyword.get(opts, :creator, Creator)

    with {:ok, current} <- DeployLedger.record_boot(ledger),
         {:ok, previous} <- DeployLedger.previous(ledger) do
      compare(previous, current, ledger, creator)
    end
  end

  defp compare(nil, _current, _ledger, _creator), do: :ok

  defp compare(previous, current, ledger, creator) do
    with {:ok, old} <- Version.parse(previous["base_version"] || ""),
         {:ok, new} <- Version.parse(current["base_version"] || "") do
      {:ok, at, _offset} = DateTime.from_iso8601(current["at"])

      case Version.compare(new, old) do
        :eq -> :ok
        :lt -> Creator.rollback(current["base_version"], at, creator)
        :gt -> create(current, at, ledger, creator)
      end
    else
      :error -> :ok
    end
  end

  defp create(current, at, ledger, creator) do
    with {:ok, rows} <- DeployLedger.list({~U[1970-01-01 00:00:00Z], at}, ledger) do
      floor = rows |> Enum.chunk_by(& &1["base_version"]) |> List.last() |> List.first()
      {:ok, before_floor, _offset} = DateTime.from_iso8601(floor["at"])
      Creator.create(%Line{source: :aiur_version, key: "auto:version:#{current["base_version"]}", at: at, before_floor: before_floor, evidence: current}, creator)
    end
  end
end
