defmodule Aiur.SystemMemoryTest do
  use ExUnit.Case, async: false

  alias Aiur.SystemMemory

  setup do
    previous = Application.get_env(:aiur, :meminfo_source_override)
    on_exit(fn -> restore_app_env(:meminfo_source_override, previous) end)
    :ok
  end

  describe "available_mb/0" do
    test "reads MemAvailable from a realistic /proc/meminfo sample" do
      set_meminfo("""
      MemTotal:       32768000 kB
      MemFree:         1048576 kB
      MemAvailable:    6291456 kB
      Buffers:          262144 kB
      """)

      assert SystemMemory.available_mb() == 6_144
    end

    test "rounds fractional megabytes down to a conservative whole value" do
      set_meminfo("MemAvailable: 2047 kB\n")

      assert SystemMemory.available_mb() == 1
    end

    test "accepts zero available memory as a valid sample" do
      set_meminfo("MemAvailable: 0 kB\n")

      assert SystemMemory.available_mb() == 0
    end

    test "returns :unavailable for missing, malformed, or wrong-unit samples" do
      for contents <- [
            "MemFree: 1024 kB\n",
            "MemAvailable: unknown kB\n",
            "MemAvailable: 1024 bytes\n"
          ] do
        set_meminfo(contents)
        assert SystemMemory.available_mb() == :unavailable
      end
    end

    test "returns :unavailable when /proc/meminfo cannot be read" do
      Application.put_env(:aiur, :meminfo_source_override, fn -> {:error, :enoent} end)

      assert SystemMemory.available_mb() == :unavailable
    end
  end

  defp set_meminfo(contents) do
    Application.put_env(:aiur, :meminfo_source_override, fn -> {:ok, contents} end)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
