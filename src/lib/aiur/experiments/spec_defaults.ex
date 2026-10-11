defmodule Aiur.Experiments.SpecDefaults do
  @moduledoc false
  alias Aiur.Experiments.Spec

  @spec prepare(map(), keyword() | map()) :: {map(), [map()]}
  def prepare(attrs, defaults) do
    opts = Map.new(defaults)
    now = Map.get(opts, :now, DateTime.utc_now())
    now = if is_struct(now, DateTime), do: DateTime.to_iso8601(now), else: now
    attrs = stringify(attrs) |> Map.delete("existing")

    base =
      %Spec{}
      |> Spec.to_map()
      |> Map.merge(%{
        "created_at" => now,
        "updated_at" => now,
        "owner" => %{"kind" => "human", "id" => "cli"},
        "origin" => %{"kind" => "manual", "ref" => nil},
        "min_samples" => Map.get(opts, :default_min_samples, 15)
      })

    map = Map.merge(base, attrs)
    {design, errors} = design(map["design"], opts)
    map = map |> Map.put("design", design) |> Map.update!("metrics", &metrics/1)
    map = if is_nil(map["windows"]), do: Map.put(map, "windows", windows(design, opts, now)), else: map
    {map, errors}
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value) when is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value)
  defp stringify(value), do: value

  defp design(%{"kind" => "before_after", "change" => change} = design, opts) when is_map(change) do
    {change, errors} = resolve(change, opts)
    {design |> Map.put("change", change) |> Map.put_new("assign_by", "start"), errors}
  end

  defp design(design, _), do: {design, []}

  defp resolve(%{"type" => type, "ref" => ref} = change, opts) when type in ["tag", "commit"] and is_binary(ref) do
    if is_nil(change["time"]) do
      resolver = Map.get(opts, :resolve_time, fn ref -> resolve_git(ref, Map.get(opts, :repo_slug, "local/repo")) end)

      case resolver.(ref) do
        {:ok, time} -> {Map.put(change, "time", time), []}
        {:error, reason} -> {change, [%{path: "design.change.time", message: "cannot resolve #{ref}: #{inspect(reason)}"}]}
      end
    else
      {change, []}
    end
  end

  defp resolve(change, _), do: {change, []}

  defp resolve_git(ref, repo) do
    task = Task.async(fn -> System.cmd("git", ["-C", Aiur.RepoBase.base_path(repo), "log", "-1", "--format=%cI", "--end-of-options", ref], stderr_to_stdout: true) end)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {_, _}} -> {:error, :unknown_ref}
      _ -> {:error, :timeout}
    end
  end

  defp metrics(metrics) when is_list(metrics) do
    metrics
    |> Enum.with_index()
    |> Enum.map(fn
      {metric, index} when is_map(metric) -> metric |> Map.put_new("direction", "decrease") |> Map.put_new("primary", index == 0)
      {metric, _} -> metric
    end)
  end

  defp metrics(metrics), do: metrics

  defp windows(%{"kind" => "before_after", "change" => %{"time" => time}}, opts, _) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, at, _} ->
        %{"before" => %{"start" => at |> DateTime.add(-Map.get(opts, :default_before_days, 14) * 86_400) |> DateTime.to_iso8601(), "end" => time}, "after" => %{"start" => time, "end" => nil}}

      _ ->
        nil
    end
  end

  defp windows(%{"kind" => "ab"}, _, now), do: %{"observation" => %{"start" => now, "end" => nil}}
  defp windows(_, _, _), do: nil
end
