defmodule Aiur.Git do
  @moduledoc """
  Thin wrappers around git shell-outs used by Aiur subsystems that need
  out-of-band access to a remote's refs without making a GitHub REST call.

  Why exist: `git ls-remote` is the only reliable way to detect a branch
  push within seconds (the GitHub `/events` firehose lag is 30-120 seconds
  on a quiet repo). `Aiur.Events.Publisher` calls this helper on every
  poll tick for the set of running-branch refs and dedupes results against
  the firehose by `(repo, ref, sha)` so the firehose is canonical for
  payload shape, ls-remote just races the firehose for latency.
  """

  require Logger

  @typedoc """
  Result of `ls_remote/2`. Maps each `refs/heads/<branch>` ref to the SHA
  the remote currently holds. Refs the remote doesn't carry are absent
  from the map (no error).
  """
  @type refs_map :: %{String.t() => String.t()}

  @doc """
  Returns a map of `ref => sha` for each ref listed in `refs` that the
  `remote` currently exposes. Empty map if none match. Returns
  `{:error, reason}` if the `git` binary is missing or the command fails.

  Accepts a `cmd_fun:` option that takes a `{git_path, args}` tuple and
  returns `{stdout, exit_code}` — used by tests to inject a stub instead
  of shelling out.
  """
  @spec ls_remote(String.t(), [String.t()], keyword()) :: {:ok, refs_map()} | {:error, term()}
  def ls_remote(remote, refs, opts \\ []) when is_binary(remote) and is_list(refs) do
    cmd_fun = Keyword.get(opts, :cmd_fun, &default_cmd_fun/1)
    git_path = System.find_executable("git")

    cond do
      git_path == nil and not Keyword.has_key?(opts, :cmd_fun) ->
        {:error, :git_not_found}

      refs == [] ->
        {:ok, %{}}

      true ->
        do_ls_remote(cmd_fun, git_path, remote, refs)
    end
  end

  defp do_ls_remote(cmd_fun, git_path, remote, refs) do
    case cmd_fun.({git_path, ["ls-remote", remote | refs]}) do
      {output, 0} ->
        {:ok, parse_output(output)}

      {output, exit_code} ->
        {:error, {:git_ls_remote_failed, exit_code, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_ls_remote_exception, Exception.message(error)}}
  end

  defp default_cmd_fun({git_path, args}) do
    System.cmd(git_path, args, stderr_to_stdout: true)
  end

  defp parse_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ~r/\s+/, parts: 2) do
        [sha, ref] -> Map.put(acc, ref, sha)
        _ -> acc
      end
    end)
  end

  @doc """
  The `owner/name` of the `origin` remote in the current working directory,
  or `nil` when there is no git repo / origin. Used to auto-detect the repo
  for a global `.aiurconfig` that carries no repo of its own.
  """
  @spec origin_repo() :: String.t() | nil
  def origin_repo do
    case System.cmd("git", ["remote", "get-url", "origin"], stderr_to_stdout: true) do
      {output, 0} -> parse_origin_url(String.trim(output))
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc false
  @spec parse_origin_url(String.t()) :: String.t() | nil
  def parse_origin_url(url) do
    url
    |> String.replace_suffix(".git", "")
    |> String.split(~r{[/:]}, trim: true)
    |> Enum.take(-2)
    |> case do
      [owner, name] when owner != "" and name != "" -> "#{owner}/#{name}"
      _ -> nil
    end
  end
end
