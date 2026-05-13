defmodule SymphonyElixir.OsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Os

  setup do
    previous_path = System.get_env("PATH")
    previous_override = Application.get_env(:symphony_elixir, :stty_executable_override)
    previous_timeout = Application.get_env(:symphony_elixir, :stty_timeout_ms_override)

    on_exit(fn ->
      set_path(previous_path)

      restore_app_env(:stty_executable_override, previous_override)
      restore_app_env(:stty_timeout_ms_override, previous_timeout)
    end)

    :ok
  end

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
    set_path("/nonexistent")

    assert {:error, message} = Os.stty(["sane"])
    assert message =~ "not found"
  end

  test "stty/1 returns :ok when the executable exits successfully" do
    path = write_script!("exit 0\n")
    Application.put_env(:symphony_elixir, :stty_executable_override, path)

    assert :ok = Os.stty(["sane"])
  end

  test "stty/1 reports a timeout when the executable does not exit in time" do
    path = write_script!("sleep 1\n")
    Application.put_env(:symphony_elixir, :stty_executable_override, path)
    Application.put_env(:symphony_elixir, :stty_timeout_ms_override, 10)

    assert {:error, message} = Os.stty(["sane"])
    assert message =~ "timed out"
  end

  test "stty/1 reports invocation failures when the executable path is invalid" do
    Application.put_env(:symphony_elixir, :stty_executable_override, "/definitely/missing/stty")

    assert {:error, message} = Os.stty(["sane"])
    assert message =~ "invocation failed"
  end

  defp set_path(nil), do: System.delete_env("PATH")
  defp set_path(value), do: System.put_env("PATH", value)

  defp write_script!(body) do
    root = Path.join(System.tmp_dir!(), "os-test-#{System.unique_integer([:positive])}")
    path = Path.join(root, "fake-stty")
    File.mkdir_p!(root)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
