defmodule Aiur.Machine.SettingsTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias Aiur.Machine.Settings

  setup do
    home = Path.join(System.tmp_dir!(), "machine-settings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    path = Path.join(home, ".aiur/machine")
    previous = Application.get_env(:aiur, :machine_settings_path)
    Application.put_env(:aiur, :machine_settings_path, path)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :machine_settings_path, previous), else: Application.delete_env(:aiur, :machine_settings_path)
      :persistent_term.erase({Settings, path})
      Aiur.TestCleanup.rm_rf!(home)
    end)

    %{home: home, path: path}
  end

  test "missing and empty files yield the complete defaults with mobile disabled", %{path: path} do
    assert path == Settings.path()
    assert {:ok, settings} = Settings.load()
    assert settings.mobile.enabled == false
    assert {settings.gateway.host, settings.gateway.port, settings.gateway.endpoints} == {"127.0.0.1", 4710, []}
    assert {settings.pairing.secret_ttl_seconds, settings.pairing.max_devices, settings.pairing.pin_rotation_grace_seconds} == {600, 20, 604_800}
    assert settings.transport.allow_cleartext_overlay == false
    assert settings.transport.cleartext_overlay_cidrs == ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]
    assert settings.transport.tls.cert_file == nil
    put_yaml("")
    assert {:ok, ^settings} = Settings.load()
  end

  test "transport section parses all six keys and expands paths" do
    put_yaml("""
    transport:
      allow_cleartext_overlay: true
      cleartext_overlay_cidrs: ["10.0.0.0/8", "fd00::/8"]
      tls:
        cert_file: ~/cert.pem
        key_file: ~/key.pem
        bind_host: "::1"
        advertise_host: machine.example
    """)

    assert {:ok, settings} = Settings.load()
    assert settings.transport.allow_cleartext_overlay
    assert settings.transport.cleartext_overlay_cidrs == ["10.0.0.0/8", "fd00::/8"]

    assert Map.from_struct(settings.transport.tls) == %{
             cert_file: Path.expand("~/cert.pem"),
             key_file: Path.expand("~/key.pem"),
             bind_host: "::1",
             advertise_host: "machine.example"
           }
  end

  test "cleartext CIDRs reject catch-all ranges and malformed prefixes" do
    for value <- ["0.0.0.0/0", "::/0", "10.0.0.1/0", "10.0.0.0/33", "fd00::/129", "platform", "10.0.0.1", "broken/8", nil] do
      put_yaml("transport: {cleartext_overlay_cidrs: [#{if is_nil(value), do: "null", else: inspect(value)}]}")
      assert {:error, {:invalid, errors}} = Settings.load()
      assert {"transport.cleartext_overlay_cidrs", "must contain IPv4/IPv6 CIDRs with a nonzero prefix"} in errors
    end
  end

  test "all unknown nested keys are reported alongside invalid values" do
    put_yaml("""
    gateway: {hots: localhost, port: 0}
    transport: {tls: {typo: true}}
    pairing: {max_devices: 201, secret_ttl_seconds: 59, pin_rotation_grace_seconds: 3599}
    """)

    assert {:error, {:invalid, errors}} = Settings.load()
    assert {"gateway.hots", "unknown key"} in errors
    assert {"transport.tls.typo", "unknown key"} in errors

    assert Enum.map(errors, &elem(&1, 0)) == [
             "gateway.hots",
             "gateway.port",
             "pairing.max_devices",
             "pairing.pin_rotation_grace_seconds",
             "pairing.secret_ttl_seconds",
             "transport.tls.typo"
           ]

    assert {"gateway.port", "must be fixed so paired phones keep a valid endpoint (1..65535)"} in errors
  end

  test "host, endpoint, TLS, range and type errors name the offending key" do
    for {key, yaml} <- [
          {"gateway.host", "gateway: {host: 'https://bad'}"},
          {"gateway.port", "gateway: {port: 65536}"},
          {"gateway.port", "gateway: {port: nope}"},
          {"gateway.endpoints", "gateway: {endpoints: [null]}"},
          {"transport.cleartext_overlay_cidrs", "transport: {cleartext_overlay_cidrs: [null]}"},
          {"gateway.endpoints", "gateway: {endpoints: ['https://example.com/path']}"},
          {"gateway.endpoints", "gateway: {endpoints: ['https://example.com?x=1']}"},
          {"gateway.endpoints", "gateway: {endpoints: ['https://example.com#fragment']}"},
          {"gateway.endpoints", "gateway: {endpoints: ['http://user@example.com']}"},
          {"transport.tls.bind_host", "transport: {tls: {bind_host: localhost}}"},
          {"transport.tls.advertise_host", "transport: {tls: {advertise_host: 'machine:443'}}"},
          {"pairing.secret_ttl_seconds", "pairing: {secret_ttl_seconds: 3601}"},
          {"pairing.max_devices", "pairing: {max_devices: 0}"},
          {"mobile.enabled", "mobile: {enabled: null}"},
          {"gateway", "gateway: null"},
          {"gateway", "gateway: [bad]"}
        ] do
      put_yaml(yaml)
      assert {:error, {:invalid, errors}} = Settings.load()
      assert Enum.any?(errors, fn {path, message} -> path == key and message != "" end), inspect({key, errors})
    end
  end

  test "valid endpoint and pairing boundaries load" do
    put_yaml("""
    gateway: {host: localhost, port: 65535, endpoints: ['https://example.com', 'http://[::1]:4710']}
    pairing: {secret_ttl_seconds: 3600, max_devices: 200, pin_rotation_grace_seconds: 3600}
    """)

    assert {:ok, settings} = Settings.load()
    assert settings.gateway.endpoints == ["https://example.com", "http://[::1]:4710"]
    assert settings.pairing.max_devices == 200
  end

  test "partial writes preserve unknown top-level data and known sibling settings", %{path: path} do
    put_yaml("relay: {x: 1, text: 'yes', nested: [true, null, {key: value}], indexed: {1: one}}\ngateway: {port: 5000}\nmobile: {enabled: false}\n")
    assert :ok = Settings.write(%{mobile: %{enabled: true}})
    assert {:ok, settings} = Settings.load()
    assert settings.mobile.enabled
    assert settings.gateway.port == 5000
    assert {:ok, raw} = Aiur.Yaml.read_from_file(path)
    assert raw["relay"] == %{"x" => 1, "text" => "yes", "nested" => [true, nil, %{"key" => "value"}], "indexed" => %{1 => "one"}}
    assert :ok = Settings.write(%{gateway: %{endpoints: ["https://example.com"]}})
    assert {:ok, settings} = Settings.load()
    assert settings.gateway.port == 5000
    assert settings.gateway.endpoints == ["https://example.com"]
  end

  test "writes create private directory and file and refuse invalid updates", %{path: path} do
    assert :ok = Settings.write(%{mobile: %{enabled: true}})
    assert band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
    assert band(File.stat!(path).mode, 0o777) == 0o600
    original = File.read!(path)
    assert {:error, {:invalid, [{"gateway.hots", "unknown key"}]}} = Settings.write(%{gateway: %{hots: "oops"}})
    assert File.read!(path) == original
    File.chmod!(path, 0o644)
    assert {:ok, %{mobile: %{enabled: true}}} = Settings.load()
  end

  test "get retains last good settings after errors, recovers and resets on deletion", %{path: path} do
    assert :ok = Settings.write(%{mobile: %{enabled: true}})
    assert {:ok, good} = Settings.get()
    put_yaml("gateway: {port: 0}")
    assert {:ok, stale} = Settings.get()
    assert stale.mobile.enabled == true
    assert {:invalid, [{"gateway.port", _message}]} = stale.last_error
    assert {:ok, ^stale} = Settings.get()
    put_yaml("mobile: [")
    assert {:ok, %{mobile: %{enabled: true}, last_error: {:unreadable, _reason}}} = Settings.get()
    put_yaml("mobile: {enabled: false}")
    assert {:ok, %{mobile: %{enabled: false}, last_error: nil}} = Settings.get()
    File.rm!(path)
    assert {:ok, defaults} = Settings.get()
    assert defaults == %Settings{}
    assert good.last_error == nil
  end

  test "cache reuses file identity and observes an inode replacement", %{path: path} do
    put_yaml("mobile: {enabled: true}")
    assert {:ok, good} = Settings.get()
    stat = File.stat!(path)
    put_yaml("mobile: {enabled: null}")
    File.touch!(path, stat.mtime)
    assert {:ok, ^good} = Settings.get()
    assert {:error, {:invalid, [{"mobile.enabled", "must not be null"}]}} = Settings.load()
    replacement = path <> ".replacement"
    File.write!(replacement, "mobile: {enabled: null}")
    File.touch!(replacement, stat.mtime)
    File.rename!(replacement, path)
    assert {:ok, stale} = Settings.get()
    assert stale.mobile.enabled
    assert stale.last_error == {:invalid, [{"mobile.enabled", "must not be null"}]}
  end

  test "initial malformed and non-mapping files return errors and writes preserve unreadable data", %{path: path} do
    put_yaml("mobile: [")
    assert {:error, {:unreadable, _reason}} = Settings.load()
    assert {:error, {:unreadable, _reason}} = Settings.get()
    assert {:error, {:unreadable, _reason}} = Settings.write(%{mobile: %{enabled: true}})
    assert File.read!(path) == "mobile: ["
    put_yaml("[1, 2]")
    assert {:error, {:invalid, [{"", "must be a mapping"}]}} = Settings.load()
  end

  test "future regression guard: enabling machine settings never creates workflow config", %{home: home} do
    assert :ok = Settings.write(%{mobile: %{enabled: true}})
    refute File.exists?(Path.join(home, ".aiur/config"))

    for name <- ["workflow.ex", "config.ex"] do
      source = File.read!(Path.expand("../../../lib/aiur/#{name}", __DIR__))
      refute source =~ "Aiur.Machine.Settings"
      refute source =~ "~/.aiur/machine"
    end
  end

  defp put_yaml(yaml) do
    File.mkdir_p!(Path.dirname(Settings.path()))
    File.write!(Settings.path(), yaml)
  end
end
