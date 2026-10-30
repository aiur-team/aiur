defmodule Aiur.ReleaseVmArgsTest do
  use ExUnit.Case, async: true

  @templates Path.expand("../rel", __DIR__)

  test "assembled releases disable normal and dirty scheduler busy-wait without environment flags" do
    root = Path.join(System.tmp_dir!(), "release-vm-args-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule VmArgsFixture.MixProject do
      use Mix.Project
      def project do
        [app: :vm_args_fixture, version: "0.1.0",
         releases: [vm_args_fixture: [include_erts: false, rel_templates_path: #{inspect(@templates)}]]]
      end
    end
    """)

    env = [
      {"MIX_ENV", "prod"},
      {"MIX_BUILD_PATH", nil},
      {"MIX_DEPS_PATH", nil},
      {"ELIXIR_ERL_OPTIONS", nil},
      {"ERL_FLAGS", nil},
      {"ERL_AFLAGS", nil},
      {"ERL_ZFLAGS", nil}
    ]
    {output, status} = System.cmd("mix", ["release"], cd: root, env: env, stderr_to_stdout: true)
    assert status == 0, output

    vm_args = File.read!(Path.join(root, "_build/prod/rel/vm_args_fixture/releases/0.1.0/vm.args"))
    flags = vm_args |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "#")) |> Enum.join(" ") |> String.split()
    assert flags == ["+sbwt", "none", "+sbwtdcpu", "none", "+sbwtdio", "none"]
  end
end
