defmodule AiurEnginePrePrInterruptionTest do
  use ExUnit.Case, async: false

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
