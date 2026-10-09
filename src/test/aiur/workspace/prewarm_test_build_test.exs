defmodule Aiur.Workspace.PrewarmTestBuildTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "repository prewarm compiles both dev and test artifacts", %{tmp_dir: root} do
    base = Path.join(root, "base")
    bin = Path.join(root, "bin")
    File.mkdir_p!(Path.join(base, "src"))
    File.mkdir_p!(bin)
    # Stub the build command boundary while executing the shipped script.
    mise = Path.join(bin, "mise")

    File.write!(mise, """
    #!/bin/sh
    set -eu
    if [ "$*" = 'exec -- mix compile' ]; then
      mkdir -p "_build/${MIX_ENV:-dev}/lib/aiur/ebin"
      printf '%s\\n' "${MIX_ENV:-dev}" > "_build/${MIX_ENV:-dev}/lib/aiur/ebin/build.env"
    fi
    """)

    File.chmod!(mise, 0o755)
    script = Path.expand("../../../../.aiur/prewarm", __DIR__)

    env = [
      {"PATH", bin <> ":" <> System.fetch_env!("PATH")},
      {"MIX_ENV", nil},
      {"HEX_HOME", Path.join(root, "hex")},
      {"MIX_HOME", Path.join(root, "mix")},
      {"npm_config_cache", Path.join(root, "npm")}
    ]

    {output, status} = System.cmd("bash", [script], cd: base, env: env, stderr_to_stdout: true)
    assert status == 0, output
    assert File.read!(Path.join(base, "src/_build/test/lib/aiur/ebin/build.env")) == "test\n"
    assert File.read!(Path.join(base, "src/_build/dev/lib/aiur/ebin/build.env")) == "dev\n"
  end
end
