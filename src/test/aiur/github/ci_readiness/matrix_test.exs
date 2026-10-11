defmodule Aiur.GitHub.CiReadiness.MatrixTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.CiReadiness

  test "expands a matrix job name across its axis values" do
    workflow = """
    on:
      pull_request:
    jobs:
      coverage:
        name: coverage (${{ matrix.partition }}/4)
        strategy:
          matrix:
            partition: [1, 2, 3, 4]
        runs-on: ubuntu-latest
    """

    readiness =
      CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], [
        "coverage (1/4)",
        "coverage (2/4)",
        "coverage (3/4)",
        "coverage (4/4)"
      ])

    assert readiness.ready?
    assert "coverage (1/4)" in readiness.workflow_check_names
    assert "coverage (4/4)" in readiness.workflow_check_names
    refute "coverage (${{ matrix.partition }}/4)" in readiness.workflow_check_names
  end

  test "expands an include-only matrix job name" do
    workflow = """
    on:
      pull_request:
    jobs:
      build:
        name: build ${{ matrix.target }}
        strategy:
          matrix:
            include:
              - runner: ubuntu-latest
                target: linux-x64
              - runner: macos-14
                target: darwin-arm64
        runs-on: ubuntu-latest
    """

    readiness =
      CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], [
        "build linux-x64",
        "build darwin-arm64"
      ])

    assert readiness.ready?
    assert Enum.sort(readiness.workflow_check_names) == ["build darwin-arm64", "build linux-x64"]
  end

  test "honors matrix exclude when expanding job names" do
    workflow = """
    on:
      pull_request:
    jobs:
      coverage:
        name: coverage (${{ matrix.partition }}/4)
        strategy:
          matrix:
            partition: [1, 2, 3, 4]
            exclude:
              - partition: 2
        runs-on: ubuntu-latest
    """

    readiness =
      CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], [
        "coverage (1/4)",
        "coverage (3/4)",
        "coverage (4/4)"
      ])

    assert readiness.ready?
    refute "coverage (2/4)" in readiness.workflow_check_names
  end

  test "excludes every combination a partial matrix exclude entry matches" do
    workflow = """
    on:
      pull_request:
    jobs:
      test:
        name: test (${{ matrix.os }} ${{ matrix.node }})
        strategy:
          matrix:
            os: [ubuntu, macos]
            node: [16, 18]
            exclude:
              - os: ubuntu
        runs-on: ubuntu-latest
    """

    readiness =
      CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], [
        "test (macos 16)",
        "test (macos 18)"
      ])

    assert readiness.ready?
    assert "test (ubuntu 16)" not in readiness.workflow_check_names
    assert "test (ubuntu 18)" not in readiness.workflow_check_names
  end

  test "merges a matrix include into every matching combination" do
    workflow = """
    on:
      pull_request:
    jobs:
      test:
        name: test (${{ matrix.os }} ${{ matrix.mode }})
        strategy:
          matrix:
            os: [ubuntu, macos]
            node: [16, 18]
            include:
              - os: ubuntu
                mode: fast
              - os: macos
                mode: slow
        runs-on: ubuntu-latest
    """

    readiness =
      CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], [
        "test (ubuntu fast)",
        "test (macos slow)"
      ])

    assert readiness.ready?
    assert Enum.sort(readiness.workflow_check_names) == ["test (macos slow)", "test (ubuntu fast)"]
  end

  test "keeps an unresolvable matrix job name literal" do
    workflow = """
    on:
      pull_request:
    jobs:
      coverage:
        name: coverage (${{ matrix.nope }}/4)
        strategy:
          matrix:
            partition: [1, 2]
        runs-on: ubuntu-latest
    """

    readiness = CiReadiness.evaluate("develop", [{".github/workflows/ci.yml", workflow}], ["coverage (1/4)"])

    refute readiness.ready?
    assert readiness.workflow_check_names == ["coverage (${{ matrix.nope }}/4)"]
    assert {:required_check_not_produced, ["coverage (1/4)"]} in readiness.issues
  end
end
