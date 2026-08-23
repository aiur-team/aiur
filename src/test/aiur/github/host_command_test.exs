defmodule Aiur.GitHub.HostCommandTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Aiur.GitHub.HostCommand

  # A fake `gh` that records its invocation and echoes the resolved credential
  # when asked, so the host wrapper path and the bot-token naming are both
  # observable without GitHub. The wrapper lives in a dedicated fake bin
  # directory passed via the `:wrapper_dir` seam — the host wrapper's real
  # location (`System.user_home!()/.aiur/bin`) does not track a changed
  # `HOME`, so tests never touch the live host path.
  defp install_fake_gh(tmp) do
    bin = Path.join(tmp, "fake-bin")
    File.mkdir_p!(bin)
    wrapper = Path.join(bin, "gh")

    File.write!(
      wrapper,
      """
      #!/bin/sh
      printf 'args=%s\\n' "$*"
      printf 'GH_TOKEN=%s\\n' "${GH_TOKEN:-}"
      printf 'GITHUB_TOKEN=%s\\n' "${GITHUB_TOKEN:-}"
      printf 'login=%s\\n' "${FAKE_LOGIN:-real-gh}"
      """
    )

    File.chmod!(wrapper, 0o755)
    {bin, wrapper}
  end

  test "prefers the installed host guard wrapper over the real gh", %{tmp_dir: tmp} do
    {bin, wrapper} = install_fake_gh(tmp)
    assert HostCommand.find_executable(wrapper_dir: bin) == wrapper
  end

  test "falls back to the real gh when no wrapper is installed", %{tmp_dir: tmp} do
    empty_bin = Path.join(tmp, "empty-bin")
    File.mkdir_p!(empty_bin)

    assert HostCommand.find_executable(wrapper_dir: empty_bin) == System.find_executable("gh")
  end

  test "runs through the resolved host wrapper and passes arguments", %{tmp_dir: tmp} do
    {bin, _wrapper} = install_fake_gh(tmp)

    {output, 0} =
      HostCommand.run(["api", "user", "--jq", ".login"], stderr_to_stdout: true, wrapper_dir: bin)

    assert output =~ "args=api user --jq .login"
    # No bot token requested: the daemon's token is not injected.
    assert output =~ "GH_TOKEN="
    assert output =~ "GITHUB_TOKEN="
  end

  test "run with bot_token names the daemon credential in the child environment", %{tmp_dir: tmp} do
    {bin, _wrapper} = install_fake_gh(tmp)

    {output, 0} =
      HostCommand.run(["api", "user"], stderr_to_stdout: true, bot_token: "daemon-bot-token", wrapper_dir: bin)

    # GH_TOKEN carries the named credential; the inherited GITHUB_TOKEN is
    # removed from the child so a stale parent value cannot win.
    assert output =~ "GH_TOKEN=daemon-bot-token"
    assert output =~ "GITHUB_TOKEN="
    refute output =~ "GITHUB_TOKEN=daemon-bot-token"
  end
end
