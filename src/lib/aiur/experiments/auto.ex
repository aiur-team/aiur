defmodule Aiur.Experiments.Auto do
  @moduledoc "Automatic experiment line sources and deploy evidence."
  use Supervisor
  require Logger

  alias Aiur.Experiments.Auto.{AiurVersionLine, Creator, DeployLedger, FeatureLine, Line, RepoReleaseLine, WindowManager}

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
  def init(opts) do
    config = Keyword.get_lazy(opts, :config, &settings/0)
    ledger = Keyword.get(opts, :ledger_opts, [])
    creator = Keyword.get(opts, :creator_opts, [])
    sources = source_children(config, opts)
    Supervisor.init([{DeployLedger, ledger}, {Creator, Keyword.put_new(creator, :config, config)} | sources], strategy: :rest_for_one)
  end

  defp source_children(config, opts) do
    version = Keyword.get(opts, :version_opts, []) |> Keyword.put_new(:ledger_opts, Keyword.get(opts, :ledger_opts, []))
    release = Keyword.get(opts, :release_opts, []) |> Keyword.put_new(:config, config)
    feature = Keyword.get(opts, :feature_opts, []) |> Keyword.put_new(:config, config)
    if(config.version_line, do: [{AiurVersionLine, version}], else: []) ++ if(config.release_line, do: [{RepoReleaseLine, release}], else: []) ++ [{FeatureLine, feature}]
  end

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

  @spec truncate(String.t(), DateTime.t(), String.t()) :: term()
  def truncate(id, at, reason) do
    WindowManager.truncate(id, at, reason)
  catch
    :exit, {:noproc, _call} -> {:error, :unavailable}
    :exit, {:timeout, _call} -> {:error, :outcome_unknown}
  end

  defp configured_sources(config) do
    [{:aiur_version, config.version_line}, {:repo_release, config.release_line}, {:feature, true}]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(fn {source, _enabled?} -> Map.merge(%{source: source, last_seen: nil}, source_status(source)) end)
  end

  defp source_status(:repo_release) do
    if Process.whereis(RepoReleaseLine), do: RepoReleaseLine.status(), else: %{status: :unavailable}
  end

  defp source_status(:feature) do
    if Process.whereis(FeatureLine), do: FeatureLine.status(), else: %{status: :unavailable}
  end

  defp source_status(_source), do: %{}

  defp settings do
    case Aiur.Config.settings() do
      {:ok, %{experiments: %{enabled: false, auto: auto}}} -> %{auto | enabled: false}
      {:ok, %{experiments: %{auto: auto}}} -> auto
      _unconfigured -> %Aiur.Config.Schema.Experiments.Auto{}
    end
  end
end
