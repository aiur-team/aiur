defmodule Aiur.Init.AlertsTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.Alerts
  alias Aiur.Init.Templates

  setup do
    dir = Aiur.TestSupport.tmp_root!("aiur-alerts-test")
    target = Path.join([dir, ".aiur", "config"])
    File.mkdir_p!(Path.dirname(target))
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, target: target}
  end

  test "prompt_alerts returns disabled when declined", %{target: target} do
    assert Alerts.prompt_alerts(io(self()), deps(), target) == %{
             enabled: false,
             use_os_default_sounds: false,
             source_path: nil
           }
  end

  test "prompt_alerts returns enabled details when accepted", %{dir: dir, target: target} do
    source = Path.join([dir, "home", ".aiur", "alerts"])
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "custom\n")

    answers = %{
      confirm: %{
        "Add sound effects for alerts (e.g. an agent is stuck or needs your input)?" => true,
        "Found an existing alerts file at ~/.aiur/alerts — copy it into this repo's .aiur/alerts?" => true,
        "Use the built-in OS default sounds? (No = play the custom .aiur/alerts mapping)" => false
      }
    }

    assert Alerts.prompt_alerts(io(self(), answers), deps(%{global_alerts_path: fn -> source end}), target) == %{
             enabled: true,
             use_os_default_sounds: false,
             source_path: source
           }
  end

  test "write_alerts_file writes host template once and never clobbers", %{target: target} do
    path = Path.join(Path.dirname(target), "alerts")

    assert {:created, ^path} = Alerts.write_alerts_file(target, nil)
    assert File.read!(path) == Templates.alerts_template(:os.type())

    File.write!(path, "custom alerts\n")
    assert {:exists, ^path} = Alerts.write_alerts_file(target, nil)
    assert File.read!(path) == "custom alerts\n"
  end

  defp io(parent, answers \\ %{}) do
    %{
      puts: fn message ->
        send(parent, {:puts, IO.chardata_to_string(message)})
        :ok
      end,
      confirm: fn label, default -> Map.get(Map.get(answers, :confirm, %{}), label, default) end
    }
  end

  defp deps(overrides \\ %{}) do
    Map.merge(
      %{
        global_alerts_path: fn -> "/missing/alerts" end,
        existing_alerts_path: fn path -> if File.regular?(path), do: path end
      },
      overrides
    )
  end
end
