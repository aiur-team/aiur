defmodule Aiur.TestSupport.BuildHome.FixtureSource do
  @moduledoc "Raw frozen build home datasets for ExUnit and the single-worker browser harness."
  @behaviour AiurWeb.Build.DataSource

  @files ~w(live dense newrepo noqueue offline)
  @dir Path.expand("../../fixtures/build_home", __DIR__)

  def datasets, do: @files ++ ~w(unavailable hold)

  @impl true
  def subscribe(_opts), do: :ok

  @impl true
  def snapshot(opts) do
    opts
    |> Keyword.get(:dataset, Application.get_env(:aiur, :build_fixture_dataset, "live"))
    |> load(Keyword.get(opts, :dir, @dir))
  end

  defp load("unavailable", _dir), do: {:error, :fixture_unavailable}

  defp load("hold", _dir) do
    receive do
      :release -> {:error, :fixture_unavailable}
    end
  end

  defp load(dataset, dir) when dataset in @files do
    path = Path.join(dir, dataset <> ".json")

    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      {:ok, json}
    else
      _error -> {:error, {:fixture_missing, path}}
    end
  end

  defp load(_dataset, _dir), do: {:error, :unknown_dataset}
end
