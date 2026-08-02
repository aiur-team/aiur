defmodule Aiur.SystemFileDescriptorsTest do
  use ExUnit.Case, async: true

  alias Aiur.SystemFileDescriptors

  describe "sample/2" do
    test "samples the current BEAM directly on procfs hosts" do
      if File.dir?("/proc/self/fd") do
        assert %{pid: pid, used: used, limit: limit, available: available, headroom_ratio: ratio} =
                 SystemFileDescriptors.sample(System.pid())

        assert pid == System.pid()
        assert used > 0
        assert limit > 0
        assert available >= 0
        assert ratio >= 0.0 and ratio <= 1.0
      end
    end

    test "returns exact process usage, limit, available count, and headroom ratio" do
      assert %{
               pid: "4242",
               used: 4,
               limit: 256,
               available: 252,
               headroom_ratio: ratio
             } =
               SystemFileDescriptors.sample(4_242,
                 descriptor_source: fn "4242" -> {:ok, ["0", "1", "2", "7"]} end,
                 limit_source: fn "4242" -> {:ok, 256} end
               )

      assert_in_delta ratio, 252 / 256, 1.0e-12
    end

    test "samples the supplied actor pid and ignores non-descriptor directory entries" do
      assert %{pid: "99", used: 2, limit: 100, available: 98} =
               SystemFileDescriptors.sample("99",
                 descriptor_source: fn "99" -> {:ok, ["0", "3", "not-an-fd"]} end,
                 limit_source: fn "99" -> {:ok, 100} end
               )
    end

    test "clamps available headroom when usage reaches or exceeds the limit" do
      assert %{used: 3, limit: 2, available: 0, headroom_ratio: ratio} =
               SystemFileDescriptors.sample(7,
                 descriptor_source: fn "7" -> {:ok, ["0", "1", "2"]} end,
                 limit_source: fn "7" -> {:ok, 2} end
               )

      assert ratio == 0.0
    end

    test "treats emfile from either source as exhausted" do
      assert :exhausted =
               SystemFileDescriptors.sample(7,
                 descriptor_source: fn "7" -> {:error, :emfile} end,
                 limit_source: fn "7" -> {:ok, 256} end
               )

      assert :exhausted =
               SystemFileDescriptors.sample(7,
                 descriptor_source: fn "7" -> {:ok, ["0"]} end,
                 limit_source: fn "7" -> {:error, :emfile} end
               )
    end

    test "fails open as unavailable for invalid pids or ordinary source errors" do
      assert :unavailable = SystemFileDescriptors.sample(0)
      assert :unavailable = SystemFileDescriptors.sample("not-a-pid")

      assert :unavailable =
               SystemFileDescriptors.sample(7,
                 descriptor_source: fn "7" -> {:error, :enoent} end,
                 limit_source: fn "7" -> {:ok, 256} end
               )

      assert :unavailable =
               SystemFileDescriptors.sample(7,
                 descriptor_source: fn "7" -> {:ok, ["0"]} end,
                 limit_source: fn "7" -> {:error, :unavailable} end
               )
    end
  end

  describe "parse_soft_limit/1" do
    test "parses the soft Max open files value from procfs limits" do
      contents = """
      Limit                     Soft Limit           Hard Limit           Units
      Max cpu time              unlimited            unlimited            seconds
      Max open files            65536                1048576              files
      Max locked memory         8388608              8388608              bytes
      """

      assert {:ok, 65_536} = SystemFileDescriptors.parse_soft_limit(contents)
      assert {:ok, 1_024} = SystemFileDescriptors.parse_soft_limit("1024")
    end

    test "rejects unlimited, zero, and malformed limits" do
      assert {:error, :unavailable} =
               SystemFileDescriptors.parse_soft_limit("Max open files unlimited unlimited files")

      assert {:error, :unavailable} = SystemFileDescriptors.parse_soft_limit("0")
      assert {:error, :unavailable} = SystemFileDescriptors.parse_soft_limit("not a limit")
    end
  end
end
