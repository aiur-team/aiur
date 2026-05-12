defmodule SymphonyElixir.OsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Os

  test "stty/1 reports an error when an executable rejects the args" do
    # `--definitely-not-a-flag` is rejected by both BSD and GNU stty.
    case Os.stty(["--definitely-not-a-flag"]) do
      {:error, message} ->
        assert is_binary(message)
        assert message =~ "stty"

      :ok ->
        flunk("expected an error from stty with an invalid flag")
    end
  end

  test "stty/1 reports an error when stty is not on PATH" do
    previous_path = System.get_env("PATH")
    on_exit(fn -> set_path(previous_path) end)
    set_path("/nonexistent")

    assert {:error, message} = Os.stty(["sane"])
    assert message =~ "not found"
  end

  defp set_path(nil), do: System.delete_env("PATH")
  defp set_path(value), do: System.put_env("PATH", value)
end
