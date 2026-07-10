defmodule Aiur.Init.Prewarm.FailureTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.Prewarm.Failure

  test "report classifies auth failures and embeds captured output" do
    out = "fatal: Authentication failed for https://github.com/owner/repo"
    log = report({:repo_base_clone_failed, 128, out})

    assert log =~ "GitHub authentication failure"
    assert log =~ "Classic tokens need the `repo` scope"
    assert log =~ out
    assert log =~ "retries automatically on the next `aiur` run"
  end

  test "report classifies base build failures" do
    log = report({:base_build_failed, 1, "npm ERR! boom"})

    assert log =~ "base_build command failed"
    assert log =~ "npm ERR! boom"
    assert log =~ "Building the warm base just FAILED"
  end

  test "report classifies other failures" do
    log = report({:unexpected, :killed})

    assert log =~ "inspect the error above"
    assert log =~ "{:unexpected, :killed}"
    assert log =~ "retries automatically on the next `aiur` run"
  end

  defp report(reason) do
    parent = self()

    io = %{
      puts: fn message ->
        send(parent, {:puts, IO.chardata_to_string(message)})
        :ok
      end
    }

    assert :ok = Failure.report(io, "owner/repo", "mise exec -- mix compile", reason)
    puts_log()
  end

  defp puts_log(acc \\ []) do
    receive do
      {:puts, msg} -> puts_log([msg | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
