defmodule Aiur.MainLineBuild do
  @moduledoc "Reports whether the running release commit is contained in its tracked integration branch."

  require Logger
  alias Aiur.BuildStamp
  alias Aiur.Signal
  @alert "system.build.not_on_main"

  @type result :: %{status: :on_main | :not_on_main | :unknown, commit: String.t() | nil, commits_ahead: non_neg_integer() | nil, branch: String.t() | nil}

  @spec current(keyword()) :: result()
  def current(opts \\ []) do
    stamp = Keyword.get_lazy(opts, :stamp, fn -> BuildStamp.read(Keyword.get(opts, :stamp_path, Path.join(to_string(:code.root_dir()), "AIUR_BUILD_STAMP"))) end)
    commit = stamp["source_sha"]
    root = stamp["repo_root"]
    branch = Keyword.get_lazy(opts, :base_branch, &Aiur.Config.base_branch/0)
    git = Keyword.get(opts, :git, &System.cmd/3)

    if valid_sha(commit) && is_binary(root) do
      check(commit, root, branch, git)
    else
      %{status: :unknown, commit: valid_sha(commit), commits_ahead: nil, branch: branch}
    end
  rescue
    _error -> %{status: :unknown, commit: nil, commits_ahead: nil, branch: nil}
  end

  @spec line(result()) :: String.t()
  def line(%{status: :on_main, commit: sha, branch: branch}), do: "build: #{sha} (on #{branch})"
  def line(%{status: :not_on_main, commit: sha, commits_ahead: count, branch: branch}), do: "build: #{sha} NOT ON #{String.upcase(branch)} (#{count} commits ahead)"
  def line(%{status: :unknown, commit: sha}), do: "build: #{sha || "unknown"} (unknown)"

  @doc "Logs and raises an attention when this release is outside the tracked integration branch."
  @spec announce(keyword()) :: :ok
  def announce(opts \\ []) do
    case Keyword.get_lazy(opts, :current, &current/0).() do
      %{status: :not_on_main, commit: sha, commits_ahead: count, branch: branch} ->
        message = "Running build #{sha} is not on #{branch} (#{count} commits ahead)."
        Keyword.get(opts, :warn, &Logger.warning/1).(message)
        _ = Keyword.get(opts, :alert, &Signal.alert/2).(@alert, message: message, reason: message, needs_attention: true, severity: "warning")
        :ok

      _other ->
        :ok
    end
  rescue
    _error -> :ok
  end

  defp not_on_main(sha, root, branch, git) when is_binary(root) do
    base_ref = "origin/" <> branch

    with {count, 0} <- git.("git", ["-C", root, "rev-list", "--count", base_ref <> ".." <> sha], stderr_to_stdout: true),
         {count, ""} <- Integer.parse(String.trim(count)) do
      %{status: :not_on_main, commit: sha, commits_ahead: count, branch: branch}
    else
      _ -> %{status: :unknown, commit: sha, commits_ahead: nil, branch: branch}
    end
  end

  defp not_on_main(sha, _root, branch, _git), do: %{status: :unknown, commit: sha, commits_ahead: nil, branch: branch}

  defp check(sha, root, branch, git) do
    base_ref = "origin/" <> branch

    case git.("git", ["-C", root, "rev-parse", "--verify", base_ref <> "^{commit}"], stderr_to_stdout: true) do
      {_main, 0} ->
        case git.("git", ["-C", root, "merge-base", "--is-ancestor", sha, base_ref], stderr_to_stdout: true) do
          {_output, 0} -> %{status: :on_main, commit: sha, commits_ahead: 0, branch: branch}
          {_output, 1} -> not_on_main(sha, root, branch, git)
          _ -> %{status: :unknown, commit: sha, commits_ahead: nil, branch: branch}
        end

      _ ->
        %{status: :unknown, commit: sha, commits_ahead: nil, branch: branch}
    end
  end

  defp valid_sha(sha) when is_binary(sha) and byte_size(sha) == 40, do: sha
  defp valid_sha(_sha), do: nil
end
