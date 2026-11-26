defmodule Aiur.Workspace.Restack do
  @moduledoc "Restacks a remote dependent using git plumbing, without changing its checkout."

  alias Aiur.Workspace.RestackGit

  @spec propagate(Path.t(), String.t(), pos_integer(), map(), keyword()) :: term()
  def propagate(workspace, branch, blocker_pr, push, opts \\ []) do
    command = Keyword.get(opts, :command, fn path, args -> RestackGit.run(path, args, opts[:ownership]) end)
    git = fn args -> command.(workspace, args) end

    with :ok <- supported_git(git),
         :ok <- valid_ref(git, branch),
         "refs/heads/" <> upstream <- push.ref,
         :ok <- valid_ref(git, upstream),
         true <- is_integer(blocker_pr) and blocker_pr > 0,
         true <- valid_sha?(push.sha) and (is_nil(push.previous_sha) or valid_sha?(push.previous_sha)) and valid_sha?(opts[:dependent_head]),
         {:ok, snapshot} <- push_snapshot(git, branch, upstream, blocker_pr),
         true <- snapshot.blocker == push.sha and snapshot.dependent == opts[:dependent_head] do
      propagate_snapshot(git, branch, blocker_pr, snapshot, push, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_evidence}
    end
  end

  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40,64}\z/, sha)

  defp push_snapshot(git, branch, upstream, number) do
    namespace = "refs/aiur/propagate/#{number}"

    with {:ok, _} <- call(git, ["fetch", "--no-tags", "origin", "+refs/heads/#{upstream}:#{namespace}/blocker", "+refs/heads/#{branch}:#{namespace}/dependent"]),
         {:ok, blocker} <- call(git, ["rev-parse", "#{namespace}/blocker"]),
         {:ok, dependent} <- call(git, ["rev-parse", "#{namespace}/dependent"]) do
      {:ok, %{blocker: blocker, dependent: dependent}}
    end
  end

  defp propagate_snapshot(git, branch, number, snapshot, push, opts) do
    case git.(["merge-base", "--is-ancestor", push.sha, snapshot.dependent]) do
      {_, 0} -> {:ok, :already_contained}
      {_, 1} -> propagate_history(git, branch, number, snapshot, push, opts)
      _ -> {:error, :ancestry_unavailable}
    end
  end

  defp propagate_history(git, branch, number, snapshot, push, opts) do
    case ancestry(git, push.previous_sha, push.sha) do
      {_, 0} -> restack(git, branch, number, push.sha, push.sha, snapshot.dependent, Keyword.put(opts, :title, "Integrate blocker ##{number} push"))
      {_, 1} -> {:rewrite, []}
      _ -> {:history_unavailable, []}
    end
  end

  defp ancestry(_git, nil, _new), do: :unknown
  defp ancestry(git, old, new), do: git.(["merge-base", "--is-ancestor", old, new])

  @spec run(Path.t(), String.t(), pos_integer(), String.t(), String.t(), keyword()) ::
          {:ok, :already_contained | {:pushed, String.t()}} | {:conflict, [String.t()]} | {:error, term()}
  def run(workspace, branch, blocker_pr, integration, merge_sha, opts \\ []) do
    command = Keyword.get(opts, :command, fn path, args -> RestackGit.run(path, args, opts[:ownership]) end)
    git = fn args -> command.(workspace, args) end

    with :ok <- supported_git(git),
         :ok <- valid_ref(git, branch),
         :ok <- valid_ref(git, integration),
         true <- is_integer(blocker_pr) and blocker_pr > 0,
         true <- is_binary(merge_sha) and Regex.match?(~r/\A[0-9a-f]{40,64}\z/, merge_sha),
         {:ok, %{base: base, blocker: blocker, dependent: dependent}} <- snapshot(git, branch, blocker_pr, integration),
         {_, 0} <- git.(["merge-base", "--is-ancestor", merge_sha, base]) do
      case git.(["merge-base", "--is-ancestor", merge_sha, dependent]) do
        {_, 0} -> remember(git, branch, dependent, :already_contained)
        {_, 1} -> restack(git, branch, blocker_pr, base, blocker, dependent)
        _ -> {:error, :ancestry_unavailable}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_evidence}
    end
  end

  defp snapshot(git, branch, blocker_pr, integration) do
    namespace = "refs/aiur/restack/#{blocker_pr}"
    refs = ["+refs/heads/#{integration}:#{namespace}/base", "+refs/pull/#{blocker_pr}/head:#{namespace}/blocker", "+refs/heads/#{branch}:#{namespace}/dependent"]

    with {:ok, _} <- call(git, ["fetch", "--no-tags", "origin" | refs]),
         {:ok, base} <- call(git, ["rev-parse", "#{namespace}/base"]),
         {:ok, blocker} <- call(git, ["rev-parse", "#{namespace}/blocker"]),
         {:ok, dependent} <- call(git, ["rev-parse", "#{namespace}/dependent"]) do
      {:ok, %{base: base, blocker: blocker, dependent: dependent}}
    end
  end

  defp restack(git, branch, blocker_pr, base, blocker, dependent, opts \\ []) do
    with {:ok, merge_base} <- call(git, ["merge-base", dependent, blocker]),
         {:ok, tree} <- merge_tree(git, merge_base, base, dependent),
         message = "#{Keyword.get(opts, :title, "Restack after ##{blocker_pr} merged")}\n\nAiur-Restack: blocker=##{blocker_pr} blocker-head=#{blocker} base=#{base}",
         {:ok, commit} <- call(git, ["commit-tree", tree, "-p", dependent, "-p", base, "-m", message]),
         :ok <- Keyword.get(opts, :before_push, fn -> :ok end).() do
      lease = if opts == [], do: [], else: ["--force-with-lease=refs/heads/#{branch}:#{dependent}"]

      case git.(["push", "--porcelain"] ++ lease ++ ["origin", "#{commit}:refs/heads/#{branch}"]) do
        {_, 0} -> remember(git, branch, commit, {:pushed, commit})
        {output, _} -> push_error(output)
      end
    else
      {:conflict, paths} ->
        with {:ok, _} <- call(git, ["update-ref", "refs/aiur/restack/conflict/#{branch}", base]), do: {:conflict, paths}

      error ->
        error
    end
  end

  defp remember(git, branch, commit, result) do
    with {:ok, _} <- call(git, ["update-ref", "refs/aiur/restack/pending/#{branch}", commit]), {:ok, _} <- call(git, ["update-ref", "-d", "refs/aiur/restack/conflict/#{branch}"]), do: {:ok, result}
  end

  defp push_error(output) do
    if String.contains?(output, ["[rejected]", "[remote rejected]"]), do: {:error, :remote_moved}, else: {:error, :push_failed}
  end

  defp merge_tree(git, merge_base, base, dependent) do
    case git.(["merge-tree", "--write-tree", "--name-only", "-z", "--merge-base=#{merge_base}", base, dependent]) do
      {output, 0} -> {:ok, output |> String.split("\0", parts: 2) |> hd() |> String.trim()}
      {output, 1} -> {:conflict, output |> String.split("\0\0", parts: 2) |> hd() |> String.split("\0", trim: true) |> tl() |> Enum.uniq()}
      _ -> {:error, :merge_tree_failed}
    end
  end

  defp supported_git(git) do
    case git.(["version"]) do
      {"git version " <> version, 0} -> supported_version(version)
      _ -> {:error, :unsupported_git}
    end
  end

  defp supported_version(version) do
    case Regex.run(~r/\A(\d+)\.(\d+)/, version) do
      [_, major, minor] -> if String.to_integer(major) > 2 or (major == "2" and String.to_integer(minor) >= 40), do: :ok, else: {:error, :unsupported_git}
      _ -> {:error, :unsupported_git}
    end
  end

  defp valid_ref(git, ref) when is_binary(ref) and ref != "" do
    case git.(["check-ref-format", "refs/heads/#{ref}"]) do
      {_, 0} -> :ok
      _ -> {:error, :invalid_ref}
    end
  end

  defp valid_ref(_git, _ref), do: {:error, :invalid_ref}

  defp call(git, args) do
    case git.(args) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> {:error, {:git_failed, hd(args)}}
    end
  end
end
