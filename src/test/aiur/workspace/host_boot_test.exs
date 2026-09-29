defmodule Aiur.Workspace.HostBootTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.HostBoot

  test "accepts only canonical kernel boot UUIDs" do
    assert {:ok, "2f5526b4-931a-4e7f-a8ca-dc3f24f362b9"} =
             HostBoot.parse("2f5526b4-931a-4e7f-a8ca-dc3f24f362b9\n")

    assert :unknown = HostBoot.parse(String.duplicate("x", 36))
    assert :unknown = HostBoot.parse("2f5526b4-931a-4e7f-a8ca-dc3f24f362b9-extra")
    assert :unknown = HostBoot.parse("2f5526b4-931a-4e7f-a8ca-dc3f24f362bz")
  end
end
