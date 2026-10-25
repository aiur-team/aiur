defmodule Aiur.Experiments.Auto.LiveSignal do
  @moduledoc false
  alias Aiur.Experiments.Auto.{BuildStamp, DeployLedger, RepoReleaseLine, TagReader}
  alias Aiur.Experiments.Paths
  alias Aiur.RepoBase
  alias Aiur.Workspace.WipPreservation.Command

  @spec resolve(map(), map(), DateTime.t(), keyword()) :: {:ok, map()} | :pending | {:error, term()}
  def resolve(merge, config, now, opts \\ []) do
    repo = Keyword.get_lazy(opts, :repo, fn -> RepoBase.base_path(Paths.repo()) end)
    signal = signal(config.feature_live_signal, repo, opts)
    result = find(signal, merge, now, repo, Keyword.put(opts, :config, config))

    case result do
      {:ok, evidence} -> {:ok, Map.put(evidence, "live_signal", signal)}
      _ when signal == "merge" -> result
      _ -> fallback(result, merge, config, now, signal)
    end
  end

  @spec signal(String.t(), Path.t(), keyword()) :: String.t()
  def signal("auto", _repo, opts) do
    stamp = Keyword.get_lazy(opts, :stamp, &BuildStamp.read/0)
    managed = Keyword.get(opts, :managed_repo, Paths.repo()) |> String.downcase()
    build_repo = Keyword.get_lazy(opts, :build_repo, &BuildStamp.repo_root/0)
    origin = if is_binary(build_repo), do: git(build_repo, ["remote", "get-url", "origin"]), else: {:error, :unknown_build}
    if stamp.source_sha && matches?(origin, managed), do: "daemon_boot", else: "merge"
  end

  def signal(signal, _repo, _opts), do: signal

  defp matches?({:ok, origin}, managed) do
    origin = origin |> String.trim() |> String.trim_trailing(".git") |> String.downcase()
    String.ends_with?(origin, "/" <> managed) or String.ends_with?(origin, ":" <> managed)
  end

  defp matches?(_unknown, _managed), do: false

  defp find("merge", merge, _now, _repo, _opts), do: {:ok, %{"at" => merge["at"], "merge_sha" => merge["sha"]}}

  defp find("daemon_boot", merge, now, repo, opts) do
    read = Keyword.get(opts, :deploys, &DeployLedger.list/1)

    with {:ok, rows} <- read.({time(merge["at"]), DateTime.add(now, 1)}) do
      row = rows |> Enum.sort_by(& &1["at"]) |> Enum.find(&contains?(repo, merge["sha"], &1["source_sha"]))
      if row, do: {:ok, %{"at" => row["at"], "source_sha" => row["source_sha"], "boot_id" => row["boot_id"]}}, else: :pending
    end
  end

  defp find("release", merge, _now, repo, opts) do
    path = Keyword.get(opts, :release_path, Path.join(Paths.root(), "auto-release-seen.json"))

    case Aiur.JsonStore.read(path, []) do
      {:ok, tags} when is_list(tags) -> release_line(tags, merge, repo, opts)
      {:ok, _invalid} -> {:error, :invalid_seen_tags}
      error -> error
    end
  end

  defp release_line(tags, merge, repo, opts) do
    dates =
      for tag <- tags,
          RepoReleaseLine.eligible?(tag, Keyword.fetch!(opts, :config)),
          {:ok, at} <- [TagReader.date(repo, tag)],
          contains?(repo, merge["sha"], "refs/tags/" <> tag),
          DateTime.compare(at, time(merge["at"])) != :lt,
          do: {at, tag}

    case Enum.sort_by(dates, fn {at, _tag} -> DateTime.to_unix(at) end) do
      [{at, tag} | _rest] -> {:ok, %{"at" => DateTime.to_iso8601(at), "tag" => tag}}
      [] -> :pending
    end
  end

  defp fallback(result, merge, config, now, signal) do
    if DateTime.diff(now, time(merge["at"])) >= config.live_signal_max_wait_hours * 3_600 do
      {:ok, %{"at" => merge["at"], "merge_sha" => merge["sha"], "live_signal" => signal, "live_signal_fallback" => true}}
    else
      result
    end
  end

  @spec contains?(Path.t(), String.t() | nil, String.t() | nil) :: boolean()
  def contains?(repo, merge, source) when is_binary(merge) and is_binary(source) do
    with {:ok, _} <- git(repo, ["cat-file", "-e", source <> "^{commit}"]), {:ok, _} <- git(repo, ["merge-base", "--is-ancestor", merge, source]), do: true, else: (_ -> false)
  end

  def contains?(_repo, _merge, _source), do: false

  defp git(repo, args) do
    case Command.run("git", ["-C", repo | args], timeout_ms: 10_000, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> {:ok, output}
      _failed -> {:error, :git_unavailable}
    end
  end

  defp time(value), do: value |> DateTime.from_iso8601() |> elem(1)
end
