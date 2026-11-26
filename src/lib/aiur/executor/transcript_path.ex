defmodule Aiur.Executor.TranscriptPath do
  @moduledoc """
  Validates Executor transcript locators without trusting payload-supplied roots.

  The `:agent_id` option requires Claude's `<session_id>/subagents/agent-<agent_id>.jsonl`
  layout, binding the agent to its parent session. Codex agent filenames retain
  the provisional `rollout-*-<agent_id>.jsonl` rule; that layout is unverified
  until the real-CLI capture in MP-E3-C4-T02 confirms it.
  """

  @spec validate(term(), String.t(), term(), keyword()) :: {:ok, Path.t() | nil} | {:error, atom()}
  def validate(path, harness, session_id, opts \\ [])
  def validate(nil, _harness, _session_id, _opts), do: {:ok, nil}

  def validate(path, harness, session_id, opts) when is_binary(path) and is_binary(session_id) do
    home = Keyword.get_lazy(opts, :home, &System.user_home!/0)
    root = Path.join(home, root(harness))

    with :ok <- contained(path, root),
         :ok <- regular_chain(path, root),
         {:ok, stat} <- File.lstat(path),
         {:ok, owner} <- File.stat(home),
         :ok <- owned(stat.uid, owner.uid),
         :ok <- matches(path, harness, session_id, opts) do
      {:ok, path}
    end
  end

  def validate(_path, _harness, _session_id, _opts), do: {:error, :invalid_path}
  defp root("claude"), do: ".claude/projects"
  defp root("codex"), do: ".codex/sessions"
  defp root(_harness), do: "__invalid_harness__"

  defp contained(path, root) do
    if Path.type(path) == :absolute and ".." not in Path.split(path) and String.starts_with?(path, root <> "/"), do: :ok, else: {:error, :outside_root}
  end

  defp regular_chain(path, root) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        directories = Stream.iterate(Path.dirname(path), &Path.dirname/1) |> Enum.take_while(&(&1 != Path.dirname(Path.dirname(root))))
        if Enum.all?(directories, &match?({:ok, %{type: :directory}}, File.lstat(&1))), do: :ok, else: {:error, :not_regular}

      _ ->
        {:error, :not_regular}
    end
  end

  defp owned(uid, uid), do: :ok
  defp owned(_uid, _owner), do: {:error, :wrong_owner}

  defp matches(path, harness, id, opts) do
    accepted? =
      case Keyword.fetch(opts, :agent_id) do
        :error -> session_name?(Path.basename(path), harness, id)
        {:ok, agent} when is_binary(agent) and agent != "" -> agent_path?(path, harness, id, agent)
        _ -> false
      end

    if accepted?, do: :ok, else: {:error, :session_mismatch}
  end

  defp agent_path?(path, "claude", session, agent) do
    Path.basename(path) == "agent-#{agent}.jsonl" and Path.basename(Path.dirname(path)) == "subagents" and
      Path.basename(Path.dirname(Path.dirname(path))) == session
  end

  defp agent_path?(path, harness, _session, agent), do: session_name?(Path.basename(path), harness, agent)
  defp session_name?(name, "claude", id), do: name == id <> ".jsonl"
  defp session_name?(name, "codex", id), do: String.starts_with?(name, "rollout-") and String.ends_with?(name, "-#{id}.jsonl")
  defp session_name?(_name, _harness, _id), do: false
end
