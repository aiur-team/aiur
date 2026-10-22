defmodule AiurEnginePrePrInterruptionTest do
  use ExUnit.Case, async: false

  test "an existing PR that gh cannot read fails pre-pr" do
    fixture = AiurEnginePrePrTest.fixture("unreadable-pr")
    repo = Path.join(fixture, "repo")
    AiurEnginePrePrTest.git!(repo, ["switch", "-c", "feature"])

    File.write!(
      Path.join(fixture, "bin/gh"),
      "#!/usr/bin/env bash\necho 'HTTP 502: Bad Gateway' >&2\nexit 1\n"
    )

    {output, status} = AiurEnginePrePrTest.run_pre_pr(fixture, repo, gate_mode: "pass")

    assert status == 1
    assert output =~ "FAIL refresh-pr-body-evidence (could not read PR with gh)"
    assert output =~ "HTTP 502"
  end

  test "no PR yet skips the refresh and asks for a rerun after gh pr create" do
    fixture = AiurEnginePrePrTest.fixture("no-pr")
    repo = Path.join(fixture, "repo")
    AiurEnginePrePrTest.git!(repo, ["switch", "-c", "feature"])

    {output, status} = AiurEnginePrePrTest.run_pre_pr(fixture, repo, gate_mode: "pass")

    assert status == 0

    assert output =~
             "SKIP refresh-pr-body-evidence (no PR yet; rerun aiur pre-pr after gh pr create)"
  end

  test "pre-pr interrupted by TERM emits its partial result and exits with signal status" do
    fixture = AiurEnginePrePrTest.fixture("term-interruption")
    repo = Path.join(fixture, "repo")
    AiurEnginePrePrTest.git!(repo, ["switch", "-c", "feature"])

    File.write!(
      Path.join(fixture, "bin/mise"),
      "#!/usr/bin/env bash\nif [[ ! -e \"#{fixture}/term-sent\" ]]; then touch \"#{fixture}/term-sent\"; target=\"$(ps -o ppid= -p \"$PPID\" | tr -d ' ')\"; kill -TERM \"$target\"; fi\nexit 0\n"
    )

    File.chmod!(Path.join(fixture, "bin/mise"), 0o755)

    {output, status} = AiurEnginePrePrTest.run_pre_pr(fixture, repo, gate_mode: "pass")

    assert status == 143, output
    assert output =~ "INTERRUPTED pre-pr command received TERM"
    assert output =~ "Result: FAIL"
    assert String.ends_with?(output, "--- end aiur pre-pr result ---\n")
  end
end
