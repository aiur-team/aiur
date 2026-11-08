defmodule Aiur.Gateway.DiscoveryTest do
  use ExUnit.Case, async: false

  alias Aiur.Gateway.{Discovery, Hello}

  @hello %{
    "gateway_id" => "AAAA",
    "gateway_label" => "nook",
    "build" => "1",
    "tls_fingerprint_sha256" => nil,
    "enrollment" => "closed"
  }

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-discovery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "remote-instances.yaml")
    previous = Application.get_env(:aiur, :gateway_registry_path)
    Application.put_env(:aiur, :gateway_registry_path, path)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :gateway_registry_path, previous), else: Application.delete_env(:aiur, :gateway_registry_path)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, path: path}
  end

  defp registry(path, id), do: File.write!(path, "version: 1\ninstances:\n  nook:\n    url: http://nook:4001\n    gateway_id: #{id}\n")
  defp no_tailscale, do: [tailscale_executable: nil]

  defp status(peers), do: Jason.encode!(%{"Peer" => peers})
  defp runner(json), do: fn _exe, _args, _timeout -> {json, 0} end

  test "without a tailscale binary lists registry entries only", %{path: path} do
    registry(path, "AAAA")
    before = File.read!(path)

    result = Discovery.discover(no_tailscale() ++ [http_get: fn _ -> {:ok, @hello} end])

    assert result.tailscale_found == false
    assert [%{name: "nook", status: "enrolled", gateway_id: "AAAA"}] = result.rows
    assert File.read!(path) == before
  end

  test "an unanswered registry entry is unreachable, a pin mismatch is not enrolled", %{path: path} do
    registry(path, "BBBB")
    assert [%{status: "identity mismatch"}] = Discovery.discover(no_tailscale() ++ [http_get: fn _ -> {:ok, @hello} end]).rows
    assert [%{status: "unreachable"}] = Discovery.discover(no_tailscale() ++ [http_get: fn _ -> {:error, :timeout} end]).rows
  end

  test "only online tag:gateway peers are probed; hello gets no credential", %{path: path} do
    registry(path, "AAAA")
    test = self()

    peers = %{
      "a" => %{"DNSName" => "up.ts.net.", "Online" => true, "Tags" => ["tag:gateway"]},
      "b" => %{"DNSName" => "down.ts.net.", "Online" => false, "Tags" => ["tag:gateway"]},
      "c" => %{"DNSName" => "plain.ts.net.", "Online" => true, "Tags" => nil}
    }

    get = fn url ->
      send(test, {:probed, url})
      {:ok, %{@hello | "gateway_id" => if(String.contains?(url, "up.ts.net"), do: "CCCC", else: "AAAA")}}
    end

    result = Discovery.discover(tailscale_executable: "tailscale", tailscale_runner: runner(status(peers)), port: 4001, http_get: get)

    assert_received {:probed, "http://up.ts.net:4001/api/v1/gateway/hello"}
    refute_received {:probed, "http://down.ts.net:4001/api/v1/gateway/hello"}
    refute_received {:probed, "http://plain.ts.net:4001/api/v1/gateway/hello"}
    assert Enum.map(result.rows, &{&1.name, &1.status}) == [{"nook", "enrolled"}, {"up.ts.net", "discovered (not enrolled)"}]
  end

  test "a hello with an extra key is unrecognised and shows nothing from the body", %{path: path} do
    registry(path, "AAAA")
    result = Discovery.discover(no_tailscale() ++ [http_get: fn _ -> {:ok, Map.put(@hello, "hostname", "secret")} end])
    assert [%{status: "answered, unrecognised", gateway_id: nil}] = result.rows
  end

  test "hello keys match the discovery contract" do
    assert Enum.sort(Hello.keys()) == Enum.sort(Enum.map(Map.keys(@hello), &String.to_atom/1))
  end

  test "default hello follows the bind" do
    for {ip, expected} <- [
          {{127, 0, 0, 1}, true},
          {{100, 101, 102, 103}, true},
          {{0xFD7A, 0x115C, 0xA1E0, 0, 0, 0, 0, 1}, true},
          {{0, 0, 0, 0}, false},
          {{192, 168, 1, 5}, false},
          {{100, 128, 0, 1}, false}
        ] do
      assert Hello.enabled?(nil, ip) == expected
    end

    assert Hello.enabled?(true, {0, 0, 0, 0})
    refute Hello.enabled?(false, {127, 0, 0, 1})
  end
end
