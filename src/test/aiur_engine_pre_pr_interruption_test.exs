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
    assert output =~ "Result: FAIL"
    assert output =~ "INTERRUPTED gate mix format --check-formatted received TERM"
    assert output =~ "--- end aiur pre-pr result ---\n--- failed gate output ---\n"
  end
end
