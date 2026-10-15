defmodule Aiur.Experiments.Auto do
  @moduledoc "Automatic experiment line sources and deploy evidence."
  use Supervisor
  require Logger

  alias Aiur.Experiments.Auto.{Creator, DeployLedger, Line}

  @spec child_specs(keyword()) :: [Supervisor.child_spec() | {module(), keyword()}]
  def child_specs(opts \\ []) do
    config = Keyword.get_lazy(opts, :config, &settings/0)
    if Keyword.get(opts, :recording?, true) and config.enabled, do: [{__MODULE__, opts}], else: []
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    case Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__)) do
      {:error, reason} ->
        Logger.warning("automatic experiments unavailable: #{inspect(reason)}")
        :ignore

      result ->
        result
    end
  end

  @impl true
  def init(opts), do: Supervisor.init([{DeployLedger, Keyword.get(opts, :ledger_opts, [])}, {Creator, Keyword.get(opts, :creator_opts, [])}], strategy: :one_for_one)

  @spec create(Line.t()) :: {:ok, term()} | {:error, term()}
  def create(line) do
    Creator.create(line)
  catch
    :exit, {:noproc, _call} -> {:error, :unavailable}
    :exit, {:timeout, _call} -> {:error, :outcome_unknown}
  end

  @spec status() :: map()
  def status do
    config = settings()
    sources = if config.enabled, do: configured_sources(config), else: []
    %{enabled: config.enabled, sources: sources, deploy_ledger: not is_nil(Process.whereis(DeployLedger)), creator: not is_nil(Process.whereis(Creator))}
  end

  @spec previous_deploy(keyword()) :: {:ok, map() | nil} | {:error, term()}
  def previous_deploy(opts \\ []), do: DeployLedger.previous(opts)

  @spec deploys({DateTime.t(), DateTime.t()}, keyword()) :: {:ok, [map()]} | {:error, term()}
  def deploys(range, opts \\ []), do: DeployLedger.list(range, opts)

  defp configured_sources(config) do
    [{:aiur_version, config.version_line}, {:repo_release, config.release_line}, {:feature, true}]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(fn {source, _enabled?} -> %{source: source, last_seen: nil} end)
  end

  defp settings do
    case Aiur.Config.settings() do
      {:ok, %{experiments: %{enabled: false, auto: auto}}} -> %{auto | enabled: false}
      {:ok, %{experiments: %{auto: auto}}} -> auto
      _unconfigured -> %Aiur.Config.Schema.Experiments.Auto{}
    end
  end
end
