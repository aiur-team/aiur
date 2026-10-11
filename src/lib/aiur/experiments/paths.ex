defmodule Aiur.Experiments.Paths do
  @moduledoc false

  @spec root() :: Path.t()
  def root do
    Application.get_env(:aiur, :experiments_dir) || Aiur.RepoBase.experiments_path(repo())
  end

  @spec repo() :: String.t()
  def repo do
    case Aiur.Config.settings() do
      {:ok, %{tracker: %{github: %{repo: repo}}}} when is_binary(repo) and repo != "" -> repo
      _other -> "local/repo"
    end
  end

  @spec valid_id?(term()) :: boolean()
  def valid_id?(id), do: is_binary(id) and Regex.match?(~r/^[a-z0-9][a-z0-9._-]{2,79}$/, id)

  @spec experiment(String.t()) :: Path.t()
  def experiment(id) do
    if valid_id?(id), do: Path.join(root(), id), else: raise(ArgumentError, "invalid experiment id")
  end

  @spec file(String.t(), String.t()) :: Path.t()
  def file(id, name), do: Path.join(experiment(id), name)

  @spec ids() :: {:ok, [String.t()]} | {:error, term()}
  def ids do
    case File.ls(root()) do
      {:ok, names} -> {:ok, Enum.filter(names, &(valid_id?(&1) and File.dir?(Path.join(root(), &1)))) |> Enum.sort()}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end
end
