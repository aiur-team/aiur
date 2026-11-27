defmodule Aiur.MainLineBuild do
  @moduledoc "Reports whether the running release commit is contained in its tracked main branch."

  require Logger
  alias Aiur.BuildStamp
  alias Aiur.Signal
  @alert "system.build.not_on_main"

  @type result :: %{status: :on_main | :not_on_main | :unknown, commit: String.t() | nil, commits_ahead: non_neg_integer() | nil}

  @spec current(keyword()) :: result()
  def current(opts \\ []) do
    stamp = Keyword.get_lazy(opts, :stamp, fn -> BuildStamp.read(Keyword.get(opts, :stamp_path, Path.join(to_string(:code.root_dir()), "AIUR_BUILD_STAMP"))) end)
    commit = stamp["source_sha"]
    root = stamp["repo_root"]
    git = Keyword.get(opts, :git, &System.cmd/3)

    if valid_sha(commit) && is_binary(root) do
      check(commit, root, git)
    else
      %{status: :unknown, commit: valid_sha(commit), commits_ahead: nil}
    end
  rescue
    _error -> %{status: :unknown, commit: nil, commits_ahead: nil}
  end

  @spec line(result()) :: String.t()
  def line(%{status: :on_main, commit: sha}), do: "build: #{sha} (on main)"
  def line(%{status: :not_on_main, commit: sha, commits_ahead: count}), do: "build: #{sha} NOT ON MAIN (#{count} commits ahead)"
  def line(%{status: :unknown, commit: sha}), do: "build: #{sha || "unknown"} (unknown)"

  @doc "Logs and raises an attention when this release is outside tracked main."
  @spec announce(keyword()) :: :ok
  def announce(opts \\ []) do
    case Keyword.get_lazy(opts, :current, &current/0).() do
      %{status: :not_on_main, commit: sha, commits_ahead: count} ->
        message = "Running build #{sha} is not on main (#{count} commits ahead)."
        Keyword.get(opts, :warn, &Logger.warning/1).(message)
        _ = Keyword.get(opts, :alert, &Signal.alert/2).(@alert, message: message, reason: message, needs_attention: true, severity: "warning")
        :ok

      _other ->
        :ok
    end
  rescue
    _error -> :ok
  end

  defp not_on_main(sha, root, git) when is_binary(root) do
    with {count, 0} <- git.("git", ["-C", root, "rev-list", "--count", "origin/main.." <> sha], stderr_to_stdout: true),
         {count, ""} <- Integer.parse(String.trim(count)) do
      %{status: :not_on_main, commit: sha, commits_ahead: count}
    else
      _ -> %{status: :unknown, commit: sha, commits_ahead: nil}
    end
  end

  defp not_on_main(sha, _root, _git), do: %{status: :unknown, commit: sha, commits_ahead: nil}

  defp check(sha, root, git) do
    case git.("git", ["-C", root, "rev-parse", "--verify", "origin/main^{commit}"], stderr_to_stdout: true) do
      {_main, 0} ->
        case git.("git", ["-C", root, "merge-base", "--is-ancestor", sha, "origin/main"], stderr_to_stdout: true) do
          {_output, 0} -> %{status: :on_main, commit: sha, commits_ahead: 0}
          {_output, 1} -> not_on_main(sha, root, git)
          _ -> %{status: :unknown, commit: sha, commits_ahead: nil}
        end

      _ ->
        %{status: :unknown, commit: sha, commits_ahead: nil}
    end
  end

  defp valid_sha(sha) when is_binary(sha) and byte_size(sha) == 40, do: sha
  defp valid_sha(_sha), do: nil
end
