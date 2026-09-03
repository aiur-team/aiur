defmodule Aiur.Rtk do
  @moduledoc """
  Admission gate and savings reader for `rtk`, the CLI output-compression proxy.

  rtk wraps a shell command and filters its output before an agent reads it
  (`git status` -> `rtk git status`). It is an optimization, never a
  correctness fix, so it is opt-in behind `agent.rtk.enabled` and off by
  default.

  ## Why an admission gate rather than a plain flag

  rtk ships a Claude Code `PreToolUse` hook that rewrites *every* bash command
  an agent runs, `gh` included. `gh` in an agent workspace is not the real
  `gh`: it is `priv/github_quota_guard.sh`, the wrapper that meters GitHub
  spend, stamps agent comment markers, and validates that a filed ticket
  carries a dispatch disposition. Anything that reshapes an agent's `gh` calls
  is therefore reshaping the governance path, so this module refuses to enable
  rtk at all unless the host's rtk configuration excludes `gh` from rewriting
  (`[hooks] exclude_commands = ["gh"]`).

  The check is a behavioural probe, not a config-file parse: `rtk hook check`
  is rtk's own dry-run of its rewriter, so it answers the question actually at
  stake ("would this invocation be rewritten?") rather than a proxy for it. A
  future rtk that changes where or how exclusions are spelled still gets
  classified correctly.

  Refusing is the deliberate behaviour. Silently enabling rtk with `gh`
  rewriting live would put an unaudited transform in front of the budget
  guard, and a compression saving is never worth an ungoverned credential
  path.

  ## What this module does not do

  It never puts `rtk` on an agent's `PATH` and never installs the hook. On a
  host where rtk is installed it is already reachable — the agent `PATH` is
  the daemon's with only release ERTS entries removed — so availability is not
  the gap. It also carries no credential: nothing here reads or forwards
  `GITHUB_TOKEN` (#2356).
  """

  require Logger

  # The probe invocation. `gh pr view 1` is a read-only command that rtk has a
  # dedicated filter for, so it is the case most likely to be rewritten — if
  # this one is excluded, the blanket `gh` exclusion is in force.
  @gh_probe "gh pr view 1"

  # rtk prints the rewritten command when it would rewrite, and a line starting
  # with this when it would not.
  @no_rewrite_marker "No rewrite for:"

  @probe_timeout_ms 5_000

  @type status ::
          :disabled
          | {:unavailable, :not_installed}
          | {:unavailable, :probe_failed}
          | {:refused, :gh_rewrite_not_excluded}
          | {:ok, String.t()}

  @type savings :: %{
          commands: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          saved_tokens: non_neg_integer(),
          savings_pct: float()
        }

  @doc """
  Whether the operator asked for rtk. Fails closed: a config that cannot be
  read leaves rtk off, because enabling a command rewriter is never the safe
  reading of a broken config.
  """
  @spec enabled?() :: boolean()
  @spec enabled?(term()) :: boolean()
  def enabled?(settings \\ Aiur.Config.settings_uncached()) do
    case settings do
      {:ok, %{agent: %{rtk: %{enabled: enabled}}}} -> enabled
      _other -> false
    end
  end

  @doc """
  Resolve rtk's admission state.

  Returns `{:ok, version}` only when rtk is enabled, installed, and its hook
  demonstrably leaves `gh` alone. Every other outcome is a distinct reason so
  a caller can say which one happened rather than collapsing them to "off".
  """
  @spec status(keyword()) :: status()
  def status(opts \\ []) do
    if Keyword.get_lazy(opts, :enabled?, &enabled?/0) do
      admit(opts)
    else
      :disabled
    end
  end

  defp admit(opts) do
    case executable(opts) do
      nil ->
        {:unavailable, :not_installed}

      rtk ->
        with {:ok, version} <- version(rtk, opts),
             :excluded <- gh_rewrite_state(rtk, opts) do
          {:ok, version}
        else
          :rewritten ->
            Logger.warning(
              "rtk is enabled but its hook would rewrite `#{@gh_probe}`. Refusing to enable it: " <>
                "rewriting `gh` reshapes the calls the GitHub quota guard governs. " <>
                ~s(Add `exclude_commands = ["gh"]` under `[hooks]` in rtk's config, then retry.)
            )

            {:refused, :gh_rewrite_not_excluded}

          {:error, reason} ->
            Logger.warning("rtk probe failed: #{inspect(reason)}")
            {:unavailable, :probe_failed}
        end
    end
  end

  defp version(rtk, opts) do
    case run(rtk, ["--version"], opts) do
      {:ok, output} -> {:ok, output |> String.trim() |> String.split() |> List.last()}
      other -> other
    end
  end

  # `rtk hook check` reports "would rewrite" as exit 0 and "no rewrite" as exit
  # 1, so a non-zero status here is a verdict rather than a failure and status
  # 1 has to be admitted. The verdict is then read from stdout: exit 1 is also
  # what a genuinely broken invocation returns, and only the marker line
  # distinguishes "rtk considered this and declined to rewrite" from "rtk could
  # not answer". Absent the marker the state is unknown, and unknown is
  # reported as an error rather than assumed excluded.
  defp gh_rewrite_state(rtk, opts) do
    case run(rtk, ["hook", "check", @gh_probe], opts, [0, 1]) do
      {:ok, output} ->
        cond do
          String.contains?(output, @no_rewrite_marker) -> :excluded
          String.contains?(output, "rtk #{@gh_probe}") -> :rewritten
          true -> {:error, {:unrecognized_probe_output, String.slice(output, 0, 200)}}
        end

      other ->
        other
    end
  end

  @doc """
  Token savings rtk has recorded, from `rtk gain -f json`.

  `{:error, :no_data}` is returned when rtk has run no commands. This is the
  distinction the surface depends on: with an empty history rtk reports
  `total_commands: 0` alongside `avg_savings_pct: 0.0`, and rendering that
  `0%` would claim rtk saved nothing when in truth it has not run. An absent
  measurement and a measured zero are different facts and are kept apart here
  rather than in the renderer.
  """
  @spec savings(keyword()) :: {:ok, savings()} | {:error, atom()}
  def savings(opts \\ []) do
    case status(opts) do
      {:ok, _version} -> read_savings(opts)
      :disabled -> {:error, :disabled}
      {:unavailable, reason} -> {:error, reason}
      {:refused, reason} -> {:error, reason}
    end
  end

  defp read_savings(opts) do
    with rtk when is_binary(rtk) <- executable(opts) || {:error, :not_installed},
         {:ok, output} <- run(rtk, ["gain", "-f", "json"], opts),
         {:ok, %{"summary" => summary}} <- Jason.decode(output) do
      decode_summary(summary)
    else
      {:error, %Jason.DecodeError{}} -> {:error, :unparsable}
      {:error, reason} -> {:error, reason}
      {:ok, _other} -> {:error, :unexpected_payload}
    end
  end

  defp decode_summary(%{"total_commands" => commands}) when not is_integer(commands),
    do: {:error, :unexpected_payload}

  defp decode_summary(%{"total_commands" => 0}), do: {:error, :no_data}

  defp decode_summary(%{"total_commands" => commands} = summary) when commands > 0 do
    {:ok,
     %{
       commands: commands,
       input_tokens: number(summary, "total_input"),
       output_tokens: number(summary, "total_output"),
       saved_tokens: number(summary, "total_saved"),
       savings_pct: summary |> number("avg_savings_pct") |> to_float() |> Float.round(1)
     }}
  end

  defp decode_summary(_summary), do: {:error, :unexpected_payload}

  defp number(summary, key) do
    case Map.get(summary, key) do
      value when is_number(value) -> value
      _other -> 0
    end
  end

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0

  defp executable(opts) do
    Keyword.get_lazy(opts, :rtk_path, fn -> System.find_executable("rtk") end)
  end

  # Bounded so a wedged rtk cannot hang the caller: `savings/1` is read from a
  # LiveView mount, where a blocking call would stall the page rather than the
  # probe.
  defp run(rtk, args, opts, allowed_statuses \\ [0]) do
    runner = Keyword.get(opts, :runner, &default_runner/2)
    timeout = Keyword.get(opts, :timeout_ms, @probe_timeout_ms)

    task = Task.async(fn -> runner.(rtk, args) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} when is_integer(status) ->
        if status in allowed_statuses,
          do: {:ok, output},
          else: {:error, {:exit_status, status}}

      {:exit, reason} ->
        {:error, {:exit, reason}}

      nil ->
        {:error, :timeout}
    end
  end

  defp default_runner(rtk, args), do: System.cmd(rtk, args, stderr_to_stdout: true)
end
