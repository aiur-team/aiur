defmodule Aiur.Experiments.Auto.TagReader do
  @moduledoc false
  alias Aiur.RepoBase.Clone
  alias Aiur.Workspace.WipPreservation.Command

  @spec list(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(repo) do
    with {:ok, output} <- git(repo, ["ls-remote", "--tags", "--refs", "origin"]) do
      {:ok, Regex.scan(~r/^[0-9a-f]+\s+refs\/tags\/(.+)$/m, output, capture: :all_but_first) |> List.flatten()}
    end
  end

  @spec date(Path.t(), String.t()) :: {:ok, DateTime.t()} | {:error, term()}
  def date(repo, tag) do
    with {:ok, _output} <- git(repo, ["fetch", "origin", "tag", tag, "--no-tags"]),
         {:ok, output} <- git(repo, ["for-each-ref", "--format=%(creatordate:iso-strict)", "refs/tags/#{tag}"]),
         {:ok, at, _offset} <- DateTime.from_iso8601(String.trim(output)) do
      {:ok, at}
    end
  end

  defp git(repo, args) do
    if File.dir?(repo) do
      env = Clone.git_auth_env()

      case Command.run("git", ["-C", repo | args], timeout_ms: 60_000, stderr_to_stdout: true, env: env) do
        {:ok, {output, 0}} -> {:ok, output}
        {:ok, {_output, status}} -> {:error, {:git_failed, status}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unavailable}
    end
  end
end
