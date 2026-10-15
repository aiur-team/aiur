defmodule Aiur.Experiments.Auto.LineMerge do
  @moduledoc false
  alias Aiur.Experiments
  alias Aiur.Experiments.Auto.{BuildStamp, Line, SpecBuilder}
  alias Aiur.Experiments.Reader

  @spec target(Line.t(), map()) :: {:ok, String.t() | nil} | {:error, term()}
  def target(%Line{source: :feature}, _config), do: {:ok, nil}

  def target(line, config) do
    with {:ok, details} <- details() do
      duplicate = Enum.find(details, &duplicate?(&1, line))
      close_release = if line.source == :repo_release, do: recent_release(details, line, config.release_min_interval_days)
      {:ok, if(duplicate || close_release, do: (duplicate || close_release).spec["id"])}
    end
  end

  @spec attach(String.t(), Line.t()) :: {:ok, map()} | {:error, term()}
  def attach(id, line) do
    with {:ok, detail} <- Experiments.fetch(id),
         :ok <- annotate_once(id, detail, line.key, line.at, "concurrent change: #{line.source} #{SpecBuilder.ref(line)}", %{source: to_string(line.source), evidence: line.evidence}) do
      {:ok, %{id: id}}
    end
  end

  @spec rollback(String.t(), DateTime.t()) :: :ok | {:error, term()}
  def rollback(version, at) do
    with {:ok, details} <- details() do
      details
      |> Enum.filter(&(version_experiment?(&1) and open_at?(&1.spec, at) and not rollback_seen?(&1, at)))
      |> Enum.reduce_while(:ok, &truncate(&1, version, at, &2))
    end
  end

  defp rollback_seen?(detail, at), do: Enum.any?(detail.annotations, &(&1["auto_line_key"] == "rollback:#{DateTime.to_iso8601(at)}"))

  defp truncate(detail, version, at, :ok) do
    windows = put_in(detail.spec["windows"], ["after", "end"], DateTime.to_iso8601(at))

    with {:ok, _spec} <- Experiments.amend(detail.spec["id"], %{windows: windows}, "auto"),
         :ok <- annotate_once(detail.spec["id"], detail, "rollback:#{DateTime.to_iso8601(at)}", at, "rollback to #{version}", %{}) do
      {:cont, :ok}
    else
      error -> {:halt, error}
    end
  end

  defp details do
    with {:ok, rows} <- Experiments.list() do
      Enum.reduce_while(rows, {:ok, []}, &collect_detail/2)
    end
  end

  defp collect_detail(row, {:ok, acc}) do
    case automatic_detail(row.id) do
      {:ok, nil} -> {:cont, {:ok, acc}}
      {:ok, detail} -> {:cont, {:ok, [detail | acc]}}
      error -> {:halt, error}
    end
  end

  defp automatic_detail(id) do
    with {:ok, spec, read_only?} <- Reader.spec(id) do
      source = get_in(spec, ["design", "change", "evidence", "source"])
      if not read_only? and source in ["aiur_version", "repo_release"], do: Experiments.fetch(id), else: {:ok, nil}
    end
  end

  defp duplicate?(detail, line) do
    evidence = get_in(detail.spec, ["design", "change", "evidence"]) || %{}
    opposite = if line.source == :aiur_version, do: "repo_release", else: "aiur_version"
    root = %{"source" => evidence["source"], "auto_line_key" => detail.spec["key"], "at" => DateTime.to_iso8601(time(detail))}
    Enum.any?([root | detail.annotations], &same_version?(&1, opposite, line))
  end

  defp same_version?(evidence, opposite, line) do
    if evidence["source"] == opposite and semver(evidence["auto_line_key"]) == semver(line.key) do
      {:ok, at, _offset} = DateTime.from_iso8601(evidence["at"])
      abs(DateTime.diff(at, line.at)) <= 14 * 86_400
    else
      false
    end
  end

  defp recent_release(details, line, days) do
    details
    |> Enum.filter(fn detail ->
      source = get_in(detail.spec, ["design", "change", "evidence", "source"])
      release? = source == "repo_release" or Enum.any?(detail.annotations, &(&1["source"] == "repo_release"))
      release? and DateTime.diff(line.at, time(detail)) >= 0 and DateTime.diff(line.at, time(detail)) < days * 86_400
    end)
    |> Enum.max_by(&DateTime.to_unix(time(&1)), fn -> nil end)
  end

  defp version_experiment?(detail) do
    get_in(detail.spec, ["design", "change", "evidence", "source"]) == "aiur_version" or Enum.any?(detail.annotations, &(&1["source"] == "aiur_version"))
  end

  defp open_at?(%{"status" => status, "windows" => %{"after" => window}}, at) when status in ["active", "draft"] do
    {:ok, from, _offset} = DateTime.from_iso8601(window["start"])
    {:ok, until, _offset} = DateTime.from_iso8601(window["end"])
    DateTime.compare(at, from) == :gt and DateTime.compare(at, until) != :gt
  end

  defp open_at?(_spec, _at), do: false

  defp time(detail) do
    {:ok, at, _offset} = DateTime.from_iso8601(detail.spec["design"]["change"]["time"])
    at
  end

  defp semver("auto:version:" <> version), do: BuildStamp.base_version(version)
  defp semver("auto:release:" <> tag), do: tag |> String.trim_leading("v") |> BuildStamp.base_version()
  defp semver(_other), do: nil

  defp annotate_once(id, detail, key, at, reason, extra) do
    if Enum.any?(detail.annotations, &(&1["auto_line_key"] == key)) do
      :ok
    else
      Experiments.annotate(id, Map.merge(extra, %{kind: "confounder", auto_line_key: key, at: DateTime.to_iso8601(at), reason: reason}), "auto")
    end
  end
end
