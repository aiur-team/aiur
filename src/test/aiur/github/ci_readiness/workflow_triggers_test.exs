defmodule Aiur.GitHub.CiReadiness.WorkflowTriggersTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.CiReadiness

  @workflow """
  name: CI
  on:
    pull_request:
      branches: [develop]
  jobs:
    test:
      name: ci / required
      runs-on: ubuntu-latest
      steps:
        - run: true
  """

  test "accepts the unconfigured pull request trigger emitted by the scaffold" do
    scaffold = CiReadiness.scaffold()

    assert CiReadiness.evaluate("main", [{".github/workflows/ci.yml", scaffold}], ["ci / required"]).ready?
    assert scaffold =~ "exit 1"
    refute scaffold =~ "exit 0"
  end

  test "does not treat a workflow excluded from the base branch as a PR workflow" do
    workflow = """
    on:
      pull_request:
        branches-ignore: [develop]
    jobs:
      test:
        name: ci / required
    """

    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"])

    refute readiness.ready?
    assert :no_pr_workflow in readiness.issues
  end

  test "matches branch glob filters for the configured base branch" do
    workflow = String.replace(@workflow, "branches: [develop]", "branches: [release/**]")

    assert CiReadiness.evaluate("release/2026", [{".github/workflows/ci.yml", workflow}], ["ci / required"]).ready?
  end

  test "honors later negative branch patterns" do
    workflow = String.replace(@workflow, "branches: [develop]", "branches: [\"**\", \"!develop\"]")

    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"])

    refute readiness.ready?
    assert :no_pr_workflow in readiness.issues
  end

  test "rejects conditional pull request workflows as universal gates" do
    workflow =
      String.replace(
        @workflow,
        "branches: [develop]",
        "types: [labeled]\n    paths: [docs/**]"
      )

    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"])

    refute readiness.ready?
    assert :no_pr_workflow in readiness.issues
  end

  test "does not count a push-only job as a pull request check" do
    workflow = String.replace(@workflow, "runs-on: ubuntu-latest", "if: github.event_name == 'push'\n      runs-on: ubuntu-latest")

    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"])

    refute readiness.ready?
    assert {:required_check_not_produced, ["ci / required"]} in readiness.issues
  end

  test "does not treat a condition with an extra gate as an unconditional PR check" do
    workflow =
      String.replace(
        @workflow,
        "runs-on: ubuntu-latest",
        "if: github.event_name == 'pull_request' && github.actor == 'maintainer'\n      runs-on: ubuntu-latest"
      )

    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"])

    refute readiness.ready?
    assert {:required_check_not_produced, ["ci / required"]} in readiness.issues
  end

  test "recognizes an always condition wrapped in GitHub expression delimiters" do
    workflow = """
    on:
      pull_request:
        branches: [develop]
    jobs:
      test:
        name: ci / required
        if: ${{ always() }}
        runs-on: ubuntu-latest
    """

    assert CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"]).ready?
  end

  test "recognizes a required job guarded only against cancellation" do
    workflow = """
    on:
      pull_request:
        branches: [develop]
    jobs:
      test:
        name: ci / required
        if: ${{ !cancelled() }}
        runs-on: ubuntu-latest
    """

    assert CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"]).ready?
  end

  test "does not treat a cancellation guard with another predicate as an unconditional PR check" do
    workflow = """
    on:
      pull_request:
        branches: [develop]
    jobs:
      test:
        name: ci / required
        if: ${{ !cancelled() && github.actor == 'maintainer' }}
        runs-on: ubuntu-latest
    """

    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"])

    refute readiness.ready?
    assert {:required_check_not_produced, ["ci / required"]} in readiness.issues
  end

  test "accepts a workflow whose pull_request trigger is a bare value" do
    workflow = """
    on:
      pull_request: true
    jobs:
      test:
        name: ci / required
        runs-on: ubuntu-latest
    """

    assert CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"]).ready?
  end

  test "accepts a workflow whose on trigger is a list" do
    workflow = """
    on: [push, pull_request]
    jobs:
      test:
        name: ci / required
        runs-on: ubuntu-latest
    """

    assert CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"]).ready?
  end

  test "accepts a workflow limited to opened and synchronize pull request types" do
    workflow = String.replace(@workflow, "branches: [develop]", "types: [opened, synchronize]")

    assert CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"]).ready?
  end

  test "matches a scalar branch filter for the configured base branch" do
    workflow = String.replace(@workflow, "branches: [develop]", "branches: develop")

    assert CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"]).ready?
  end

  test "counts a job explicitly gated to pull request events" do
    workflow =
      String.replace(
        @workflow,
        "runs-on: ubuntu-latest",
        "if: github.event_name == 'pull_request'\n    runs-on: ubuntu-latest"
      )

    assert CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"]).ready?
  end

  test "ignores a non-map job when collecting pull request check names" do
    workflow = """
    on:
      pull_request:
    jobs:
      test: hello
    """

    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["ci / required"])

    refute readiness.ready?
    assert {:required_check_not_produced, ["ci / required"]} in readiness.issues
  end

  test "does not treat an unparseable workflow as a pull request gate" do
    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", "::: not yaml :::"}], ["ci / required"])

    refute readiness.ready?
    assert :no_pr_workflow in readiness.issues
  end

  test "falls back to the job id when a pull request job has no name" do
    workflow = """
    on:
      pull_request:
    jobs:
      test:
        runs-on: ubuntu-latest
    """

    assert CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["test"]).ready?
  end

  test "matches question-mark branch glob patterns" do
    workflow = String.replace(@workflow, "branches: [develop]", "branches: [release-2-?]")

    assert CiReadiness.evaluate("release-2-6", [{".github/workflows/ci.yml", workflow}], ["ci / required"]).ready?
    refute CiReadiness.evaluate("release-2-16", [{".github/workflows/ci.yml", workflow}], ["ci / required"]).ready?
  end
end
