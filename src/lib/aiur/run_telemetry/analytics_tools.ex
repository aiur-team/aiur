defmodule Aiur.RunTelemetry.AnalyticsTools do
  @moduledoc false
  require Logger

  alias Aiur.RunTelemetry.Summaries

  @spec resolve(term(), keyword()) :: {:ok, Path.t()} | {:error, :reduce_dir_not_found}
  def resolve(override, opts \\ []) do
    result = if is_binary(override), do: {:ok, Path.expand(override)}, else: discover(opts)
    log_once(result)
    result
  rescue
    _error -> {:error, :reduce_dir_not_found}
  end

  defp discover(opts) do
    checkout = Keyword.get_lazy(opts, :checkout, fn -> Aiur.RepoBase.base_path(Summaries.repo_url()) end)
    release = Keyword.get_lazy(opts, :release_root, fn -> :aiur |> :code.lib_dir() |> to_string() |> Path.join("../..") |> Path.expand() end)
    cwd = Keyword.get_lazy(opts, :cwd, &File.cwd!/0)

    case Enum.find(Enum.map([checkout, release, cwd], &Path.join(&1, "analytics")), &File.dir?/1) do
      nil -> {:error, :reduce_dir_not_found}
      dir -> {:ok, dir}
    end
  end

  defp log_once({:ok, dir}) do
    key = {__MODULE__, :resolved}

    if :persistent_term.get(key, nil) == nil do
      :persistent_term.put(key, dir)
      Logger.info("analytics tools resolved dir=#{dir}")
    end
  end

  defp log_once(_unavailable), do: :ok
end
