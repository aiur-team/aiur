defmodule Aiur.Experiments.Catalog do
  @moduledoc "The available metric definitions, read only from the base checkout."
  alias Aiur.Experiments.{Packs.Loader, Paths}

  @spec load(map()) :: map()
  def load(ctx \\ %{}) do
    settings = settings()
    root = Map.get_lazy(ctx, :repo_path, fn -> Aiur.RepoBase.base_path(Paths.repo()) end)
    modules = Map.get(ctx, :builtin_packs, Application.get_env(:aiur, :experiment_metric_packs, []))
    builtins = Map.new(modules, &{&1.id(), &1})
    reserved = Enum.uniq(["delivery-speed" | Map.keys(builtins)])
    dirs = Map.get(ctx, :pack_dirs, Map.get(settings, :pack_dirs, [".aiur/experiments/packs"]))
    disabled = Map.get(ctx, :disabled_packs, Map.get(settings, :disabled_packs, []))
    {consumers, problems} = Loader.load(root, dirs, reserved)
    packs = builtins |> Map.merge(consumers) |> Map.drop(disabled)

    metrics =
      Map.new(packs, fn {id, pack} -> {id, definitions(pack)} end)
      |> Enum.flat_map(fn {id, definitions} -> Enum.map(definitions, &{id <> "/" <> &1.id, %{&1 | pack: id}}) end)
      |> Map.new()

    %{metrics: metrics, packs: packs, problems: problems}
  end

  @spec validate_refs([map()], map()) :: :ok | {:error, [map()]}
  def validate_refs(metrics, ctx \\ %{}) do
    catalog = load(ctx)
    errors = metrics |> Enum.with_index() |> Enum.flat_map(fn {metric, index} -> validate_ref(metric, index, catalog.metrics) end)
    if errors == [], do: :ok, else: {:error, errors}
  end

  defp validate_ref(metric, index, catalog) do
    ref = Map.get(metric, "ref", Map.get(metric, :ref))

    if Map.has_key?(catalog, ref) do
      []
    else
      closest = catalog |> Map.keys() |> Enum.sort_by(&String.jaro_distance(to_string(ref), &1), :desc) |> Enum.take(3)
      [%{path: "metrics.#{index}.ref", message: "unknown metric #{inspect(ref)}; closest ids: #{Enum.join(closest, ", ")}"}]
    end
  end

  defp definitions(module) when is_atom(module), do: module.metrics()
  defp definitions(pack), do: pack["metrics"]

  defp settings do
    case Aiur.Config.settings() do
      {:ok, %{experiments: settings}} -> settings
      _ -> %{}
    end
  end
end
