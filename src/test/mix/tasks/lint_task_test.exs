defmodule Mix.Tasks.LintTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lint

  test "runs every check before reporting all failures" do
    test_pid = self()

    runner = fn
      "specs.check", [] ->
        send(test_pid, {:ran, "specs.check"})
        Mix.raise("missing specs")

      "credo", ["--strict"] ->
        send(test_pid, {:ran, "credo --strict"})
        exit({:shutdown, 2})
    end

    error_output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/lint failed: specs.check, credo --strict/, fn ->
          Lint.run_with(runner)
        end
      end)

    assert_received {:ran, "specs.check"}
    assert_received {:ran, "credo --strict"}
    assert error_output =~ "lint: specs.check failed: missing specs"
    assert error_output =~ "lint: credo --strict failed: exit status 2"
  end

  test "returns successfully when every check passes" do
    runner = fn _task, _args -> :ok end

    assert :ok = Lint.run_with(runner)
  end

  test "reports each check's failure without blaming the check that passed" do
    test_pid = self()

    failures = [
      {"specs.check", fn -> Mix.raise("missing specs") end},
      {"credo --strict", fn -> exit({:shutdown, 2}) end}
    ]

    Enum.each(failures, fn {failed_label, fail} ->
      runner = fn task, args ->
        label = Enum.join([task | args], " ")
        send(test_pid, {:ran, label})

        if label == failed_label do
          fail.()
        end
      end

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, "lint failed: #{failed_label}", fn ->
          Lint.run_with(runner)
        end
      end)

      assert_received {:ran, "specs.check"}
      assert_received {:ran, "credo --strict"}
    end)
  end
end
