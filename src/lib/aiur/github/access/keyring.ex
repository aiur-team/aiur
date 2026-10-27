defmodule Aiur.GitHub.Access.Keyring do
  @moduledoc false
  require Logger
  alias Aiur.GitHub.HostCommand

  # Bound on the `gh auth token` keyring shell-out (#2393). A gh that prompts on
  # a locked keyring, blocks on a slow/unreachable host, or waits on a missing
  # GUI credential agent would otherwise hang boot before any log line on the
  # keyring-only path a new developer takes. 5s matches the webhook admission
  # deadline idiom and is far longer than a healthy local keyring lookup; the
  # default is overridable through `AIUR_GH_KEYRING_TIMEOUT_MS` for a
  # slow-but-succeeding setup (see `keyring_timeout_ms/1`).
  @keyring_command_timeout_ms 5_000
  @keyring_timeout_env "AIUR_GH_KEYRING_TIMEOUT_MS"
  @keyring_os_pid_key :aiur_gh_keyring_os_pid

  @doc """
  The default timeout (milliseconds) for the `gh auth token` keyring shell-out,
  applied when `#{@keyring_timeout_env}` is unset.

  Exposed so the boot-safety bound is testable: a boot stall from a locked
  keyring must stay well under the ten-minute mark, and a mutation of the
  private `@keyring_command_timeout_ms` would otherwise ship silently because
  every test injects its own `timeout_ms`.
  """
  @spec keyring_command_timeout_ms() :: pos_integer()
  def keyring_command_timeout_ms, do: @keyring_command_timeout_ms

  @doc """
  The effective keyring lookup timeout in milliseconds.

  `:timeout_ms` in `opts` wins, then `#{@keyring_timeout_env}` when it is a
  positive integer, then the compiled-in `keyring_command_timeout_ms/0`
  default. The env override exists so a slow-but-succeeding keyring (e.g. an
  interactive unlock prompt that legitimately takes longer than the 5s default)
  is not converted into a spurious "no keyring credential" at boot; an invalid
  env value is ignored rather than crashing boot.
  """
  @spec keyring_timeout_ms(keyword()) :: pos_integer()
  def keyring_timeout_ms(opts \\ []) do
    Keyword.get(opts, :timeout_ms, env_keyring_timeout_ms() || @keyring_command_timeout_ms)
  end

  defp env_keyring_timeout_ms do
    case System.get_env(@keyring_timeout_env) do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {ms, ""} when ms > 0 -> ms
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Query the gh keyring with the env tokens CLEARED so gh returns the stored
  login rather than echoing the (possibly stale) env var.

  Returns the stored PAT as a trimmed string, or `nil` when gh is absent, not
  logged in via keyring (headless/CI), the lookup fails, or the shell-out does
  not answer within `keyring_timeout_ms/1`. A timeout is treated exactly like
  an absent gh — "no keyring credential" — never a fatal error, and it is
  logged at warning level so a stalled keyring is attributable instead of a
  silent boot hang.

  Logs at debug level immediately before the shell-out, so even a boot that
  hangs (within the timeout) leaves a line to read rather than stopping with no
  output.

  Routed through the host guard so the keyring lookup is admitted and recorded
  like every other gh call (#2353). This is the single source of truth for
  "does a gh keyring credential exist": `resolve_pat_token/1` uses it as its
  runtime fallback, and the boot gate in `Aiur.Env` consults the same function
  so a keyring-only `gh auth login` satisfies the GitHub credential requirement
  before any env token is set.

  ## Options

    * `:timeout_ms` — bound on the shell-out, overriding the
      `#{@keyring_timeout_env}` default (test seam).
    * `:run_fun` — how the `gh auth token` command runs, defaulting to the
      `HostCommand`-routed port spawn. Test seam so the in-task rescue that
      turns a raising runner into "no keyring credential" is load-bearing.
    * `:wrapper_dir` — the guard-wrapper directory `HostCommand.find_executable/1`
      prefers, as in that function. Test seam that selects the process TOPOLOGY
      of the shell-out, which the timeout kill has to survive either way: with a
      wrapper installed the port child is the wrapper and the real `gh` is a
      GRANDchild (a dev box), while with no wrapper the `gh` on PATH is the
      DIRECT child (CI). Pointing this at an empty directory reproduces the CI
      topology deliberately instead of only in CI — which is where the
      direct-pid kill regressed.
  """
  @spec keyring_token(keyword()) :: String.t() | nil
  def keyring_token(opts \\ []) do
    timeout_ms = keyring_timeout_ms(opts)
    wrapper_dir = Keyword.get(opts, :wrapper_dir)
    run_fun = Keyword.get(opts, :run_fun, fn -> run_gh_auth_token_command(wrapper_dir) end)

    Logger.debug(
      "aiur_boot phase=github_keyring_lookup state=starting " <>
        "command=\"gh auth token --hostname github.com\" timeout_ms=#{timeout_ms}"
    )

    case run_bounded_gh_auth_token(timeout_ms, run_fun) do
      {out, 0} -> normalize_secret(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Runs `run_fun` in a linked task so the caller can bound it. A command that
  # never returns is torn down after `timeout_ms` and the whole lookup degrades
  # to "no keyring credential" — nil — the same way an absent gh is treated,
  # never a fatal error.
  #
  # The guard must live INSIDE the task: Task.async links the task to the
  # caller, so an uncaught exception inside the task would exit it abnormally
  # and the link would kill the caller before Task.yield ever returned —
  # crashing boot on the exact new-developer box this protects. The `:run_fun`
  # seam makes that guard load-bearing: a test injects a runner that raises
  # and asserts the caller survives with nil. `catch _, _ -> nil` is included
  # because `rescue` only covers raises: a `throw` or `exit` from `run_fun`
  # would otherwise exit the linked task by the same path.
  #
  # The timeout path also kills the port child and everything it spawned.
  # Closing the task's port sends EOF but never signals the OS process, so a
  # stalled `gh` that outlived the port would keep holding the locked keyring /
  # credential-helper prompt and every later lookup would spawn another orphan.
  # The child's OS pid is published to the task's dictionary by the runner and
  # read here while the task is still alive; `kill_os_process/1` then signals
  # the direct pid, its descendants and the group it may lead (see its comment
  # for why the group alone cannot be relied on). The kill runs BEFORE the task
  # is torn down: Task.shutdown closes the port, erl_child_setup may reap the
  # child, and the OS could recycle the pid before a later kill landed on an
  # unrelated process.
  defp run_bounded_gh_auth_token(timeout_ms, run_fun) do
    task =
      Task.async(fn ->
        try do
          run_fun.()
        rescue
          _ -> nil
        catch
          _, _ -> nil
        end
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        # With the in-task guard the task never exits abnormally; kept as a
        # defensive fallback so an unexpected exit still degrades to "no
        # keyring credential" rather than a crash.
        nil

      nil ->
        os_pid = task_keyring_os_pid(task)
        kill_os_process(os_pid)
        Task.shutdown(task, :brutal_kill)

        Logger.warning(
          "aiur_boot phase=github_keyring_lookup state=timed_out " <>
            "timeout_ms=#{timeout_ms} treated_as=no_keyring_credential " <>
            "run `gh auth login` to use the gh keyring"
        )

        nil
    end
  end

  # The real runner: `gh auth token --hostname github.com` with the env tokens
  # cleared so gh returns the stored keyring login rather than echoing a
  # (possibly stale) env var. The executable is resolved through
  # HostCommand.find_executable/1 so the guard wrapper is used when installed
  # (budget admission, #2353). The command runs as a port so the bounded runner
  # can read the child's OS pid from the task dictionary and kill it and its
  # descendants on timeout — reaching a guard wrapper AND the `gh` /
  # lease-renewer it spawned, not just the direct child. Closing the port
  # alone would orphan the process.
  defp run_gh_auth_token_command(wrapper_dir) do
    case HostCommand.find_executable(wrapper_dir: wrapper_dir) do
      nil ->
        {"", 127}

      path ->
        port =
          Port.open({:spawn_executable, String.to_charlist(path)}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            {:args, ["auth", "token", "--hostname", "github.com"]},
            {:env, [{~c"GITHUB_TOKEN", ~c""}, {~c"GH_TOKEN", ~c""}]}
          ])

        Process.put(@keyring_os_pid_key, port_os_pid(port))
        collect_port_output(port)
    end
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _ -> nil
    end
  end

  defp task_keyring_os_pid(task) do
    case Process.info(task.pid, :dictionary) do
      {:dictionary, dict} ->
        case Keyword.get(dict, @keyring_os_pid_key) do
          pid when is_integer(pid) and pid > 0 -> pid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Kills the port child and everything it spawned, BY PID ONLY. Never a
  # process group.
  #
  # A process group is not a safe unit to signal from inside a CI job. On a
  # GitHub-hosted runner the whole job shares one group — measured on the
  # runner that failed #2560:
  #
  #     PID   PGID   PPID    SID  COMMAND
  #    2108   2034   2034   2034  Runner.Listener
  #    2128   2034   2108   2034  Runner.Worker
  #    2428   2034    ...   2034  the step shell (-> timeout -> make -> beam.smp)
  #
  # so a `kill -<sig> -<pgid>` that lands on that group SIGTERMs the Actions
  # runner itself. That is what #2560 looked like from outside: the job died
  # mid-step with exit 143 and "the runner has received a shutdown signal", no
  # test output at all, and no remaining step ran — including the one that
  # would have printed the partition log. An instrumented run put 8 ms between
  # this function's group signal and the runner's death.
  #
  # The group signal was never load-bearing: the descendant walk below already
  # reaches the guard wrapper, the real `gh` it spawned and any background
  # lease renewer, because it enumerates them from the live process table.
  # Signalling a group only added a way to hit processes this code never
  # spawned. Every target here is now a pid that walk actually found.
  #
  # TERM is sent first — to the root and to every descendant already
  # enumerated — so a wrapper's cleanup trap can release the budget lease
  # (SIGKILL is untrappable), then, after a brief bound for that trap to run,
  # KILL clears anything that ignored TERM. The kill runs BEFORE the task is
  # torn down: Task.shutdown closes the port, erl_child_setup may reap the
  # child, and the OS could recycle the pid before a later kill landed on an
  # unrelated process.
  #
  # NO STEP MAY SWALLOW ANOTHER. The kill used to compute
  # `[pid | descendant_os_pids(pid)]` before signalling anything, and the walk
  # parsed pgrep's (stderr-merged) output with `String.to_integer/1`. A single
  # non-numeric byte on that stream raised, the function-level `rescue _ -> :ok`
  # swallowed it, and NO signal was sent at all — silently reintroducing the
  # orphan accumulation this exists to prevent. The walk is now defensive at
  # both levels: `child_os_pids/2` parses with `Integer.parse/1` and drops
  # non-pids, and `safe_descendant_os_pids/2` degrades any walk failure to []
  # rather than aborting the kill, so the direct-pid signals always land.
  #
  # The walk still runs BEFORE the TERM, and that ordering is load-bearing in
  # the other direction: TERM kills the direct child immediately, its children
  # are reparented to init, and `pgrep -P <pid>` then finds nothing. CI proved
  # this — with the walk moved after the TERM the direct `gh` died and its
  # `sleep` grandchild was orphaned. The tree is walked again after the TERM
  # settles and the two results are unioned, so a process that only appears
  # later is still reached.
  #
  # Seams (tests only): `:signal_fun` observes the signals, `:pgrep_fun`
  # supplies the raw child-enumeration output.
  @doc false
  @spec kill_os_process(term(), keyword()) :: :ok
  def kill_os_process(pid, opts \\ [])

  def kill_os_process(pid, opts) when is_integer(pid) and pid > 0 do
    signal = Keyword.get(opts, :signal_fun, &signal_os_pid/2)

    # Enumerated BEFORE the TERM: once the root dies its children reparent to
    # init and `pgrep -P <root>` finds nothing.
    before_term = safe_descendant_os_pids(pid, opts)

    signal.("TERM", pid)
    Enum.each(before_term, &signal.("TERM", &1))

    Process.sleep(150)

    descendants = Enum.uniq(before_term ++ safe_descendant_os_pids(pid, opts))

    signal.("KILL", pid)
    Enum.each(descendants, &signal.("KILL", &1))
    :ok
  rescue
    _ -> :ok
  end

  def kill_os_process(_pid, _opts), do: :ok

  # The descendant walk can never abort the kill: any failure degrades to "no
  # descendants found" and the direct-pid signals still land.
  defp safe_descendant_os_pids(pid, opts) do
    descendant_os_pids(pid, opts)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Sends `signal` to `target`: a positive target is a pid, a negative target
  # (-pid) is the process group led by `pid`. Stderr is captured (and
  # discarded) so an ESRCH on a host where the child does not lead a group
  # cannot raise.
  # A missing `kill` binary raises `:enoent`, which would abort the whole kill
  # sequence; fall back to the shell builtin, and never let one failed signal
  # stop the remaining ones.
  defp signal_os_pid(signal, target) do
    System.cmd("kill", ["-" <> signal, Integer.to_string(target)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> shell_signal_os_pid(signal, target)
  end

  defp shell_signal_os_pid(signal, target) do
    System.cmd("sh", ["-c", "kill -#{signal} #{target} 2>/dev/null"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  # Every descendant OS pid of `pid`, recursively, enumerated from the live
  # process table via pgrep's parent filter (available on Linux and macOS).
  # Returns [] when pgrep is unavailable or the pid has no children.
  defp descendant_os_pids(pid, opts) do
    pid
    |> child_os_pids(opts)
    |> Enum.flat_map(&[&1 | descendant_os_pids(&1, opts)])
  end

  # pgrep's output is captured with `stderr_to_stdout: true`, so the stream can
  # carry a warning line as well as pids. Parse every line defensively and drop
  # what is not a pid: `String.to_integer/1` raised on the first such byte and
  # took the entire kill down with it.
  defp child_os_pids(pid, opts) do
    pgrep = Keyword.get(opts, :pgrep_fun, &run_pgrep/1)

    case pgrep.(pid) do
      {out, 0} -> parse_pids(out)
      _ -> []
    end
  end

  defp run_pgrep(pid) do
    Aiur.ProcessExhaustion.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true)
  end

  defp parse_pids(out) when is_binary(out) do
    out
    |> String.split()
    |> Enum.flat_map(fn token ->
      case Integer.parse(token) do
        {pid, ""} when pid > 0 -> [pid]
        _ -> []
      end
    end)
  end

  defp parse_pids(_out), do: []

  defp collect_port_output(port, acc \\ "") do
    receive do
      {^port, {:data, data}} -> collect_port_output(port, acc <> data)
      {^port, {:exit_status, status}} -> {acc, status}
    end
  end

  defp normalize_secret(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret(_value), do: nil
end
