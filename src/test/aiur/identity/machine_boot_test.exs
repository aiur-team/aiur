defmodule Aiur.Identity.MachineBootTest do
  use ExUnit.Case, async: true

  test "corrupt identity permits real application boot and records one attention" do
    script = ~S"""
    config = Config.Reader.read!("config/config.exs", env: :test, target: :host)
    Application.put_all_env(config)
    dir = Application.fetch_env!(:aiur, :machine_state_dir)
    File.mkdir_p!(dir)
    path = Path.join(dir, "identity.json")
    File.write!(path, "corrupt-private-label")
    {:ok, _apps} = Application.ensure_all_started(:aiur)
    true = Process.alive?(Process.whereis(Aiur.Supervisor))
    {:degraded, :identity_unreadable, _reason} = Aiur.Identity.Machine.current()
    [alert] = Aiur.AlertLedger.read(Aiur.AlertLedger.path())
      |> Enum.filter(&(&1["name"] == "system.identity.unreadable"))
    true = alert["needs_attention"]
    true = String.contains?(alert["message"], dir)
    false = String.contains?(alert["message"], "corrupt-private-label")
    :ok = Aiur.Identity.Machine.announce_degraded()
    :ok = Aiur.Identity.Machine.announce_degraded()
    1 = Aiur.AlertLedger.read(Aiur.AlertLedger.path())
      |> Enum.count(&(&1["name"] == "system.identity.unreadable"))
    "corrupt-private-label" = File.read!(path)
    IO.puts("identity-degraded-boot-ok")
    """

    paths = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))
    {output, status} = System.cmd(System.find_executable("elixir"), Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "identity-degraded-boot-ok"
  end
end
