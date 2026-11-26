defmodule AiurEnginePrePrInterruptionTest do
  use ExUnit.Case, async: false
  import Aiur.PrePrFixture

  test "an existing PR that gh cannot read fails pre-pr" do
    fixture = fixture("unreadable-pr")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])

    File.write!(
      Path.join(fixture, "bin/gh"),
      "#!/usr/bin/env bash\necho 'HTTP 502: Bad Gateway' >&2\nexit 1\n"
    )

    {output, status} = run_pre_pr(fixture, repo, gate_mode: "pass")

    assert status == 1
    assert output =~ "FAIL refresh-pr-body-evidence (could not read PR with gh)"
    assert output =~ "HTTP 502"
  end

  test "no PR yet skips the refresh and asks for a rerun after gh pr create" do
    fixture = fixture("no-pr")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])

    {output, status} = run_pre_pr(fixture, repo, gate_mode: "pass")

    assert status == 0

    assert output =~
             "SKIP refresh-pr-body-evidence (no PR yet; rerun aiur pre-pr after gh pr create)"

    result_file = Path.join(repo, ".git/aiur-pre-pr/result.txt")
    assert output =~ "aiur pre-pr result file: #{result_file}"
    assert File.read!(result_file) =~ "Result: PASS (full CI suite not run)"
  end

  test "pre-pr interrupted by TERM emits its partial result and exits with signal status" do
    fixture = fixture("term-interruption")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])

    File.write!(
      Path.join(fixture, "bin/mise"),
      "#!/usr/bin/env bash\nif [[ ! -e \"#{fixture}/term-sent\" ]]; then touch \"#{fixture}/term-sent\"; kill -TERM \"$(cat \"#{fixture}/pre-pr.pid\")\"; fi\nexit 0\n"
    )

    File.chmod!(Path.join(fixture, "bin/mise"), 0o755)

    {output, status} = run_pre_pr(fixture, repo, gate_mode: "pass")

    assert status == 143, output
    assert output =~ "INTERRUPTED pre-pr command received TERM"
    assert output =~ "Result: INTERRUPTED"
    assert output =~ "INTERRUPTED gate mix format --check-formatted received TERM"
    assert output =~ "--- end aiur pre-pr result ---\n--- failed gate output ---\n"

    durable = File.read!(Path.join(repo, ".git/aiur-pre-pr/result.txt"))
    assert durable =~ "Result: INTERRUPTED"
    assert durable =~ "INTERRUPTED pre-pr command received TERM"
  end

  test "a closing PTY's HUP stops the gate tree and leaves an INTERRUPTED result on disk" do
    fixture = fixture("hup-interruption")
    repo = Path.join(fixture, "repo")
    git!(repo, ["switch", "-c", "feature"])
    grandchild = Path.join(fixture, "grandchild.pid")
    reaped = Path.join(fixture, "grandchild.reaped")

    File.write!(
      Path.join(fixture, "bin/mise"),
      "#!/usr/bin/env bash\nsleep 30 &\nchild=$!\necho $child > \"#{grandchild}\"\ntrap 'wait \"$child\" 2>/dev/null || true; touch \"#{reaped}\"; exit 0' TERM\nkill -HUP \"$(cat \"#{fixture}/pre-pr.pid\")\"\nwait \"$child\"\n"
    )

    File.chmod!(Path.join(fixture, "bin/mise"), 0o755)

    {output, status} = run_pre_pr(fixture, repo, gate_mode: "pass")

    assert status == 129, output
    durable = File.read!(Path.join(repo, ".git/aiur-pre-pr/result.txt"))
    assert durable =~ "Result: INTERRUPTED"
    assert durable =~ "INTERRUPTED gate mix format --check-formatted received HUP"

    # The fake gate reaps its killed child before exiting; verify no process remains.
    assert File.exists?(reaped), "the fake gate did not reap its child before exiting"
    pid = String.trim(File.read!(grandchild))

    alive =
      Enum.reduce_while(1..20, true, fn _, _ ->
        case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
          {_, 0} ->
            {:cont, true}

          _ ->
            {:halt, false}
        end
      end)

    refute alive, "HUP left a gate descendant running"
  end
end
