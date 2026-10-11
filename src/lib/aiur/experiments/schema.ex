defmodule Aiur.Experiments.Schema do
  @moduledoc "Experiment file versions and the published spec schema."

  @spec current() :: pos_integer()
  def current, do: 1

  @spec migrate(map()) :: {:ok, map()} | {:error, term()}
  def migrate(%{"schema_version" => version}) when is_integer(version) and version > 1, do: {:error, {:newer_version, version}}
  def migrate(%{"schema_version" => 1} = map), do: {:ok, map}
  def migrate(%{"schema_version" => 0} = map), do: {:ok, map |> Map.put("schema_version", 1) |> Map.put_new("registered_at", nil)}
  def migrate(_), do: {:error, :unsupported_schema_version}
end
