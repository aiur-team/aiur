defmodule Aiur.TestSupport.BuildHome.UsageFixtures do
  @moduledoc false
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias AiurWeb.Build.Payload
  @dir Path.expand("../../fixtures/build_home/usage", __DIR__)

  def load(name, dir \\ @dir) do
    with {:ok, files} <- File.ls(dir),
         true <- (name <> ".json") in files,
         {:ok, body} <- File.read(Path.join(dir, name <> ".json")),
         {:ok, block} <- Jason.decode(body),
         {:ok, snapshot} <- FixtureSource.full(dataset: "live"),
         :ok <- Payload.validate(Map.put(snapshot, "usage", block)) do
      {:ok, block}
    else
      false -> {:error, :not_found}
      {:error, errors} when is_list(errors) -> {:error, {:invalid, errors}}
      _error -> {:error, :not_found}
    end
  end
end
