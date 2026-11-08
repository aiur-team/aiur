defmodule AiurWeb.ProjectsHome.PeersTest do
  use ExUnit.Case, async: true

  alias AiurWeb.ProjectsHome.Peers

  @moduletag :tmp_dir

  test "lists url peers, marks non-https off tailnet, drops inbound-only", %{tmp_dir: dir} do
    path = Path.join(dir, "remote-instances.yaml")

    File.write!(path, """
    version: 1
    instances:
      nook:
        url: https://nook.x.ts.net/
        gateway_id: ABC
        label: Nook
      lab:
        url: http://10.0.0.5:4001
      ops:
        inbound_only: true
    """)

    assert [
             %{name: "lab", label: "lab", gateway_id: nil, url: "http://10.0.0.5:4001", off_tailnet: true},
             %{name: "nook", label: "Nook", gateway_id: "ABC", url: "https://nook.x.ts.net", off_tailnet: false}
           ] = Peers.list(path)
  end

  test "a missing or unreadable registry is no peers", %{tmp_dir: dir} do
    assert Peers.list(Path.join(dir, "absent.yaml")) == []
    File.write!(Path.join(dir, "bad.yaml"), ": : [")
    assert Peers.list(Path.join(dir, "bad.yaml")) == []
  end
end
