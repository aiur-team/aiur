defmodule Aiur.AgentRunner.TurnProgress do
  @moduledoc """
  Observable-progress fingerprint for one completed agent turn, and the
  consecutive-no-op counter the continuation loop is bounded by (#2806).

  `Aiur.AgentRunner.TurnLoop.finalize_turn_completion/3` used to tail-call
  itself on nothing but the ticket's state label. On khala #198 a mislabelled
  ticket therefore took eleven continuation turns in under two minutes, each
  handed a prompt byte-identical to the last one but for `#N`, each reporting
  that there was nothing left to do. `agent.max_turns` was the only bound and
  it defaults to nil (uncapped).

  ## What counts as a no-op

  A turn is a no-op when **every** witness the loop can observe from inside
  itself is byte-identical to the previous turn's:

    * `prompt` — the digest of the prompt handed to the provider, with the
      turn counter normalized out. Two consecutive continuation prompts differ
      only in `#N`, so an unchanged digest means *the agent was given no new
      input*. Any new input that reaches the prompt (a rework continuation, a
      resumed session, a fresh cold prompt) changes it.
    * `workspace` — `HEAD`, the upstream ref, and the full porcelain status of
      the agent workspace. A turn that committed, pushed, or left one byte of
      uncommitted work changes it. Aiur's own `logs/` and `.aiur-runtime/`
      writes are in `.git/info/exclude` (see `Aiur.Workspace.GitMetadata`), so
      a turn's own bookkeeping does not read as work.
    * `issue` — the refreshed ticket's state, sorted labels, and the
      paused/parked markers. A label transition is progress.

  Every witness is compared **like for like against the previous turn** (the
  refreshed issue against the previous refreshed issue, this turn's workspace
  digest against the previous turn's), never against a differently-sourced
  baseline, so a field one source leaves unpopulated cannot masquerade as a
  change. There is no previous turn to compare turn 1 against, so turn 1 is
  never a no-op: the bound only ever ends a *continuation* run.

  A productive turn resets the counter to zero, so an arbitrarily long run of
  real work is never penalised — only a run of consecutive turns that changed
  nothing is bounded.
  """

  require Logger

  alias Aiur.{Issue, Shell}
  alias Aiur.Workspace.Remote

  @type witness :: %{
          prompt: binary(),
          workspace: binary() | {:unavailable, term()},
          issue: term()
        }

  @type t :: %{consecutive_noops: non_neg_integer(), witness: witness() | nil}

  @probe_timeout_ms 15_000

  # The turn counter is the one thing a continuation prompt is guaranteed to
  # vary, and varying it is not new input. Normalize it out so "same prompt"
  # means "same instructions".
  @turn_counter_pattern ~r/continuation turn #\d+( of \d+)?/

  # Lines the loop itself injects ABOUT the no-op run (see
  # `Aiur.AgentRunner.TurnPrompt.noop_run_bullet/1`). They are Aiur talking to
  # the agent about its own bound, not new input, and they carry the running
  # count — so leaving them in the digest would make every no-op turn look like
  # a fresh prompt and the counter could never reach the cap.
  @self_referential_prompt_line ~r/^\s*- Aiur observed that the last \d+ turn/

  @doc """
  The empty progress state a fresh agent run starts from.
  """
  @spec empty() :: t()
  def empty, do: %{consecutive_noops: 0, witness: nil}

  @doc """
  Normalizes whatever `opts[:turn_progress]` carries into a progress state.
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :turn_progress) do
      %{consecutive_noops: noops, witness: witness} when is_integer(noops) and noops >= 0 ->
        %{consecutive_noops: noops, witness: witness}

      _absent_or_malformed ->
        empty()
    end
  end

  @doc """
  The witness triple for a turn that just completed.

  `workspace_probe` is injectable so tests (and a workspace that is not a git
  checkout) do not need to shell out; it defaults to the local/remote git
  probe below.
  """
  @spec witness(String.t(), Path.t() | nil, String.t() | nil, Issue.t(), keyword()) :: witness()
  def witness(prompt, workspace, worker_host, %Issue{} = refreshed_issue, opts \\ []) do
    probe = Keyword.get(opts, :workspace_probe, &workspace_digest/2)

    %{
      prompt: prompt_digest(prompt),
      workspace: normalize_probe(probe.(workspace, worker_host)),
      issue: issue_witness(refreshed_issue)
    }
  end

  @doc """
  Folds a completed turn's witness into the progress state.

  Returns `{:noop, state}` when the turn changed nothing observable and
  `{:progress, state}` otherwise. `state.consecutive_noops` is the run of
  consecutive no-op turns ending at this one; a productive turn zeroes it.
  """
  @spec observe(t(), witness()) :: {:noop | :progress, t()}
  def observe(%{consecutive_noops: noops, witness: previous}, witness) do
    if not is_nil(previous) and previous == witness do
      {:noop, %{consecutive_noops: noops + 1, witness: witness}}
    else
      {:progress, %{consecutive_noops: 0, witness: witness}}
    end
  end

  @doc """
  Human-readable reason naming which witnesses were unchanged, for the alert
  and the log line that record the bound firing.
  """
  @spec unchanged_witnesses(witness()) :: [String.t()]
  def unchanged_witnesses(%{workspace: workspace}) do
    workspace_note =
      case workspace do
        {:unavailable, reason} -> "workspace (unreadable: #{inspect(reason)})"
        _digest -> "workspace (HEAD, upstream and porcelain status)"
      end

    ["prompt (no new input)", workspace_note, "ticket state and labels"]
  end

  @doc false
  @spec prompt_digest(String.t()) :: binary()
  def prompt_digest(prompt) when is_binary(prompt) do
    prompt
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(@self_referential_prompt_line, &1))
    |> Enum.join("\n")
    |> String.replace(@turn_counter_pattern, "continuation turn #N")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def prompt_digest(_prompt), do: "no-prompt"

  defp issue_witness(%Issue{} = issue) do
    %{
      state: issue.state,
      labels: issue.labels |> List.wrap() |> Enum.sort(),
      state_labels: issue.state_labels |> List.wrap() |> Enum.sort(),
      paused: issue.paused,
      parked: issue.parked
    }
  end

  defp normalize_probe({:ok, digest}) when is_binary(digest), do: digest
  defp normalize_probe({:error, reason}), do: {:unavailable, reason}
  defp normalize_probe(other), do: {:unavailable, {:invalid_probe_result, other}}

  @doc """
  Digest of everything a turn could have changed in the agent workspace that
  git can see: `HEAD`, the upstream ref, and the porcelain status including
  untracked files.

  Two turns with the same digest committed nothing, pushed nothing, and left
  no file changed. Returns `{:error, reason}` when the workspace cannot be
  probed at all — an unreadable workspace is recorded as `:unavailable` rather
  than guessed at, and the alert that fires on the bound says so.
  """
  @spec workspace_digest(Path.t() | nil, String.t() | nil) :: {:ok, binary()} | {:error, term()}
  def workspace_digest(workspace, worker_host \\ nil)

  def workspace_digest(workspace, nil) when is_binary(workspace) do
    case System.cmd("sh", ["-c", probe_script(workspace)], stderr_to_stdout: true) do
      {output, 0} -> {:ok, digest(output)}
      {output, status} -> {:error, {:workspace_probe_failed, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:workspace_probe_exception, Exception.message(error)}}
  end

  def workspace_digest(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    case Remote.run_remote_command(worker_host, probe_script(workspace), @probe_timeout_ms) do
      {:ok, {output, 0}} -> {:ok, digest(output)}
      {:ok, {output, status}} -> {:error, {:workspace_probe_failed, status, String.trim(output)}}
      {:error, reason} -> {:error, {:workspace_probe_unreachable, reason}}
    end
  end

  def workspace_digest(workspace, _worker_host), do: {:error, {:workspace_probe_no_workspace, workspace}}

  defp probe_script(workspace) do
    path = Shell.escape(workspace)

    [
      "cd #{path} || exit 65",
      "git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 66",
      "git rev-parse HEAD 2>/dev/null || echo detached-or-unborn",
      "git rev-parse '@{upstream}' 2>/dev/null || echo no-upstream",
      "git status --porcelain=v1 --untracked-files=all"
    ]
    |> Enum.join("\n")
  end

  defp digest(output) do
    :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)
  end
end
