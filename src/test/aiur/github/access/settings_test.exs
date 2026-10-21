defmodule Aiur.GitHub.Access.SettingsTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.Access.{Settings, StaticSettings}

  setup do
    for key <- [:github_access_settings_provider, :github_access_settings] do
      previous = Application.fetch_env(:aiur, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:aiur, key, value)
          :error -> Application.delete_env(:aiur, key)
        end
      end)
    end

    :ok
  end

  @tag :tmp_dir
  test "static settings return the supplied struct on each call", %{tmp_dir: root} do
    Application.put_env(:aiur, :github_access_settings_provider, StaticSettings)
    settings = Settings.new(root, budget: %{max_inflight: 7})
    Application.put_env(:aiur, :github_access_settings, settings)
    assert Settings.current() == settings
    Application.put_env(:aiur, :github_access_settings, %{settings | budget: %{max_inflight: 9}})
    assert Settings.current().budget.max_inflight == 9
  end

  test "an unregistered provider names the missing configuration" do
    Application.delete_env(:aiur, :github_access_settings_provider)
    assert_raise ArgumentError, ~r/github_access_settings_provider/, fn -> Settings.current() end
  end

  @tag :tmp_dir
  test "stores and broker run in a fresh VM without Aiur.Application", %{tmp_dir: root} do
    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", to_string(path)] end)
    script = Path.expand("../../../fixtures/github_access_standalone.exs", __DIR__)
    {output, status} = System.cmd(System.find_executable("elixir"), paths ++ [script, root], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "standalone GitHub access passed"
  end
end
