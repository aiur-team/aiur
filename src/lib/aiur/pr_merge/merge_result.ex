defmodule Aiur.PrMerge.MergeResult do
  @moduledoc "Checks a merge in an invocation-isolated bare cache without changing the operator checkout."
  alias Aiur.Workspace.WipPreservation.Command

  @spec check(map(), map(), keyword()) :: :ok | {:refuse, [String.t()]} | {:error, String.t()}
  def check(pr, settings, opts \\ []) do
    id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    context = %{
      id: id,
      repo: Path.join(Keyword.fetch!(opts, :repo), id),
      refs: "refs/aiur/pr-merge/#{pr.number}/#{id}",
      run: Keyword.get(opts, :run, &git/3),
      env: Keyword.get(opts, :env, []),
      puts: Keyword.get(opts, :puts, &IO.puts/1)
    }

    try do
      with :ok <- initialize(context),
           :ok <- fetch(context, Keyword.fetch!(opts, :remote), pr),
           {:ok, head} <- command(context, ["rev-parse", context.refs <> "/head"]),
           true <- String.trim(head) == pr.head or {:refuse, ["head moved during fetch"]},
           {:ok, base} <- command(context, ["rev-parse", context.refs <> "/base"]),
           true <- String.trim(base) == pr.base_sha or {:refuse, ["base moved during fetch"]},
           :ok <- overlap(context),
           {:ok, tree} <- merge_tree(context) do
        checks(context, tree, settings, opts)
      end
    after
      File.rm_rf(context.repo)
    end
  end

  defp initialize(context) do
    with :ok <- File.mkdir_p(context.repo), {:ok, _} <- command(context, ["init", "--bare"]), do: :ok
  end

  defp fetch(context, remote, pr) do
    args = ["fetch", "--no-tags", remote, "+refs/heads/#{pr.base}:#{context.refs}/base", "+refs/pull/#{pr.number}/head:#{context.refs}/head", "+refs/heads/#{pr.base}:refs/remotes/origin/#{pr.base}"]
    with {:ok, _} <- command(context, args), do: :ok
  end

  defp merge_tree(context) do
    case context.run.(context.repo, ["merge-tree", "--write-tree", context.refs <> "/base", context.refs <> "/head"], context.env) do
      {:ok, {output, 0}} -> {:ok, output |> String.split("\n") |> hd() |> String.trim()}
      {:ok, {_output, 1}} -> {:refuse, ["conflict"]}
      _ -> {:error, "git merge-tree failed"}
    end
  end

  defp overlap(context) do
    with {:ok, common} <- command(context, ["merge-base", context.refs <> "/base", context.refs <> "/head"]),
         {:ok, base} <- command(context, ["diff", "--name-only", String.trim(common), context.refs <> "/base"]),
         {:ok, head} <- command(context, ["diff", "--name-only", String.trim(common), context.refs <> "/head"]) do
      paths = Enum.filter(String.split(base, "\n", trim: true), &(&1 in String.split(head, "\n", trim: true)))
      if paths != [], do: context.puts.("NOTE overlap: " <> Enum.join(paths, ", "))
      :ok
    end
  end

  defp checks(_context, _tree, %{merge_policy: %{premerge_checks: []}}, _opts), do: :ok

  defp checks(context, tree, settings, opts) do
    root = Path.join(settings.workspace.root, "premerge")
    worktree = Path.join(root, context.id)

    try do
      with :ok <- File.mkdir_p(root),
           {:ok, commit} <-
             command(context, [
               "-c",
               "user.name=Aiur premerge",
               "-c",
               "user.email=premerge@localhost",
               "commit-tree",
               tree,
               "-p",
               context.refs <> "/base",
               "-p",
               context.refs <> "/head",
               "-m",
               "Premerge check"
             ]),
           {:ok, _} <- command(context, ["worktree", "add", "--detach", worktree, String.trim(commit)]) do
        Enum.reduce(settings.merge_policy.premerge_checks, [], &run_check(&1, worktree, &2, Keyword.put(opts, :id, context.id))) |> check_result()
      end
    after
      command(context, ["worktree", "remove", "--force", worktree])
    end
  end

  defp run_check(check, worktree, refusals, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 600_000)
    log_root = Keyword.get(opts, :log_root, Path.expand("~/.aiur/logs/pr-merge"))
    log = Path.join(log_root, "premerge-#{Keyword.fetch!(opts, :id)}-#{System.unique_integer([:positive])}.log")
    shell = "unset GH_TOKEN GITHUB_TOKEN; cd \"$1\" && exec nice sh -c \"$2\" >\"$3\" 2>&1"

    with :ok <- File.mkdir_p(log_root),
         {:ok, {_output, 0}} <- Command.run("sh", ["-c", shell, "premerge", worktree, check, log], timeout_ms: timeout) do
      refusals
    else
      {:error, {:command_timeout, _, _, _}} -> refusals ++ ["premerge check timed out: #{check}; #{log}"]
      _ -> refusals ++ ["premerge check failed: #{check}; #{log}\n#{tail(log)}"]
    end
  end

  defp check_result([]), do: :ok
  defp check_result(reasons), do: {:refuse, reasons}
  defp tail(log), do: log |> File.read() |> log_tail()
  defp log_tail({:ok, body}), do: body |> String.split("\n") |> Enum.take(-20) |> Enum.join("\n")
  defp log_tail(_error), do: "log unavailable"

  defp command(context, args) do
    case context.run.(context.repo, args, context.env) do
      {:ok, {output, 0}} -> {:ok, output}
      _ -> {:error, "git #{hd(args)} failed"}
    end
  end

  @spec git(String.t(), [String.t()], [{String.t(), String.t()}]) :: Command.result()
  def git(repo, args, env), do: Command.run("git", ["-C", repo | args], timeout_ms: 60_000, env: env, stderr_to_stdout: true)
end
