defmodule Aiur.GitHub.Config.TestFixtures do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Aiur.TestSupport, only: [write_workflow_file!: 2]
  alias Aiur.Workflow

  # Puts a fake `gh` on PATH for the duration of `fun` so the real
  # `System.cmd("gh", ...)` keyring shell-out resolves to a deterministic stub.
  # `token_script` must define the `gh auth token` behaviour and then fall
  # through: the helper appends a pass-through to the real `gh` (located before
  # PATH changed) for every other invocation, so a concurrent test that shells
  # out to `gh` still reaches the real binary instead of a stub.
  #
  # `assert_reaped: true` makes the fake `gh` record its OS pid and registers an
  # `on_exit` that fails the test if that pid is still live after the test
  # completes — the CI-hang guard from the review. A leaked never-returning
  # fake `gh` (the very process this ticket bounds) surfaces as a fast
  # assertion failure instead of a stalled ExUnit shard holding a pipe open.
  def with_fake_gh_on_path(token_script, fun, opts \\ []) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "aiur-config-fake-gh-#{unique}")
    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(bin_dir)
    fake_gh = Path.join(bin_dir, "gh")

    {pidfile, script} = fake_gh_script(token_script, unique, opts)
    pass_through = pass_through_script()

    File.write!(fake_gh, "#!/bin/sh\n" <> script <> "\n" <> pass_through)
    File.chmod!(fake_gh, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir <> ":" <> (original_path || ""))

    if pidfile, do: assert_reaped_on_exit(pidfile, "fake gh")

    try do
      fun.()
    after
      restore_path(original_path)
      File.rm_rf!(root)
    end
  end

  # Builds the fake `gh` script: with `assert_reaped: true` the fake records
  # its OS pid to a file (in a directory outside the fake-gh root, which is
  # removed before `on_exit` runs) so `assert_reaped_on_exit/2` can assert the
  # process was killed rather than leaked. Returns `{pidfile_or_nil, script}`.
  def fake_gh_script(token_script, unique, opts) do
    case Keyword.get(opts, :assert_reaped, false) do
      false ->
        {nil, token_script}

      true ->
        pid_root = Path.join(System.tmp_dir!(), "aiur-config-keyring-reap-#{unique}")
        File.mkdir_p!(pid_root)
        pidfile = Path.join(pid_root, "gh.pid")
        {pidfile, "echo $$ > #{pidfile}\n" <> token_script}
    end
  end

  # Collects every {signal, target} pair recorded by an injected `:signal_fun`.
  def drain_signals(acc \\ []) do
    receive do
      {:signal, signal, target} -> drain_signals([{signal, target} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def pass_through_script do
    case System.find_executable("gh") do
      nil -> "exit 99\n"
      path -> "exec #{path} \"$@\"\n"
    end
  end

  def restore_path(nil), do: System.delete_env("PATH")
  def restore_path(value), do: System.put_env("PATH", value)

  # Fails the test if the OS pid recorded at `pidfile` is still live when the
  # test completes, then removes the recording directory. Registered by
  # `with_fake_gh_on_path/3` with `assert_reaped: true` so a leaked
  # never-returning fake `gh` — the orphan a failed timeout-kill would leave
  # behind — is caught deterministically after the test body runs rather than
  # stalling the CI shard. The pidfile lives outside the fake-gh root because
  # that root is removed when the helper's `after` runs, before `on_exit`.
  def assert_reaped_on_exit(pidfile, label) do
    on_exit(fn ->
      try do
        case File.read(pidfile) do
          {:ok, contents} ->
            pid = contents |> String.trim() |> String.to_integer()
            refute live_process?(pid), "#{label} pid #{pid} survived the test (leaked process)"

          _ ->
            :ok
        end
      after
        Aiur.TestCleanup.rm_rf!(Path.dirname(pidfile))
      end
    end)
  end

  def write_tracker_repo!(repo) do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: repo)
  end

  def origin(repo), do: [origin_fun: fn -> repo end]

  def refuting_origin do
    [origin_fun: fn -> flunk("origin remote must not be consulted") end]
  end

  def authorization_token(opts) do
    opts
    |> Keyword.fetch!(:headers)
    |> Enum.find_value(fn
      {"Authorization", "Bearer " <> token} -> token
      _ -> nil
    end)
  end

  # Sets PATH to a directory with no executables, so `gh` is genuinely absent
  # and the {"", 127} missing-binary degradation path is exercised — the box
  # with no gh installed at all. HostCommand.run guards its System.cmd call, so
  # this never reaches the raising `:enoent` path (that one is covered by the
  # injected-runner test).
  def with_empty_path(fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "aiur-config-empty-path-#{unique}")
    File.mkdir_p!(root)

    original_path = System.get_env("PATH")
    System.put_env("PATH", root)

    try do
      fun.()
    after
      case original_path do
        nil -> System.delete_env("PATH")
        value -> System.put_env("PATH", value)
      end

      File.rm_rf!(root)
    end
  end

  # True when `pid` names a live (non-zombie) process. A process killed by
  # SIGKILL either disappears or lingers as a zombie (`ps` stat "Z") until its
  # parent reaps it; neither is a live process, so only an empty/absent stat or
  # a "Z" stat counts as dead.
  def live_process?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("sh", ["-c", "ps -o stat= -p #{pid} 2>/dev/null"]) do
      {out, 0} ->
        case String.trim(out) do
          "" -> false
          "Z" <> _ -> false
          _ -> true
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end
end
