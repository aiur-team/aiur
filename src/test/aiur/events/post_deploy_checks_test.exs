defmodule Aiur.Events.PostDeployChecksTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.PostDeployChecks

  test "extracts only standalone gates from the Local tests section" do
    body = """
    #### Context
    The change adds a durable checklist.

    #### TL;DR
    Run a real smoke after deployment.

    #### Summary
    Automated checks passed.

    ## Local tests
    Policy: partial
    Tested head: #{String.duplicate("a", 40)}
    - `mix test` -> passed
    Post-deploy check: run the real TUI smoke (operator: terminal)

    ```text
    # This section heading inside the fence is not structural.
    Post-deploy check: this is sample text, not a gate
    ```

    - Post-deploy check: confirm the physical Stream Deck input (operator: physical Stream Deck)

    #### Docs
    Post-deploy check: this is outside Local tests
    """

    assert PostDeployChecks.from_pr_body(body) == [
             "run the real TUI smoke (operator: terminal)",
             "confirm the physical Stream Deck input (operator: physical Stream Deck)"
           ]
  end

  test "ignores a gate-shaped line outside Local tests" do
    assert PostDeployChecks.from_pr_body("Post-deploy check: ignore me\n## Summary\ntext") == []
    assert PostDeployChecks.from_pr_body(nil) == []
  end
end
