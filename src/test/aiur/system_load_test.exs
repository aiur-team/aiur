defmodule Aiur.SystemLoadTest do
  use ExUnit.Case, async: false

  alias Aiur.SystemLoad

  setup do
    previous = Application.get_env(:aiur, :loadavg_source_override)
    on_exit(fn -> restore_app_env(:loadavg_source_override, previous) end)
    :ok
  end

  describe "avg1/0" do
    test "parses the 1-minute field from a /proc/loadavg line" do
      Application.put_env(:aiur, :loadavg_source_override, fn ->
        {:ok, "24.00 12.00 8.00 5/900 12345\n"}
      end)

      assert SystemLoad.avg1() == 24.0
    end

    test "parses a low load line without a trailing newline" do
      Application.put_env(:aiur, :loadavg_source_override, fn ->
        {:ok, "0.89 0.49 0.37 2/1939 1"}
      end)

      assert SystemLoad.avg1() == 0.89
    end

    test "returns :unavailable when /proc/loadavg is absent (e.g. macOS)" do
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:error, :enoent} end)

      assert SystemLoad.avg1() == :unavailable
    end

    test "returns :unavailable on unparseable contents" do
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "garbage"} end)

      assert SystemLoad.avg1() == :unavailable
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
