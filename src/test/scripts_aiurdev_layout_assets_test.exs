defmodule ScriptsAiurdevLayoutAssetsTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport.AiurdevCase

  test "build installs locked browser packages and generates checked assets before compiling" do
    root = fake_repo()
    npm_log = Path.join(root, "npm.log")

    {out, 0} = run_shim(["build"], build_env(root, npm_log))

    assert File.read!(npm_log) == "npm ci --ignore-scripts\nnpm run vendor:elk -- --check\n"
    assert before?(out, "MISE: exec -- npm run vendor:elk -- --check", "MISE: exec -- mix compile --force")
    assert File.read!(asset_path(root)) == "generated\n"
  end

  test "npm failure stops the build despite existing assets and names the recovery command" do
    for failed_step <- ["ci", "run"] do
      root = fake_repo()
      release_log = Path.join(root, "release.log")
      env = build_env(root, Path.join(root, "npm.log")) ++ [{"AIUR_FAKE_NPM_FAIL", failed_step}, {"AIUR_FAKE_MISE_RELEASE_LOG", release_log}]

      {out, 1} = run_shim(["build"], env)

      assert out =~ "ELK asset generation failed; release build stopped"
      assert out =~ "npm ci --ignore-scripts && npm run vendor:elk -- --check"
      assert out =~ "offline first build"
      refute File.exists?(release_log)
      refute File.exists?(release_stamp_path(root))
      assert File.read!(asset_path(root)) == "fixture"
    end
  end

  test "missing generated assets make an otherwise current release rebuild" do
    root = fake_repo()
    seed_ready_release(root)
    File.rm!(asset_path(root))
    npm_log = Path.join(root, "npm.log")

    {_out, 0} = run_shim(["__ensure-build"], build_env(root, npm_log))

    assert File.read!(asset_path(root)) == "generated\n"
    assert File.read!(npm_log) =~ "npm run vendor:elk -- --check"
  end

  test "newer authored worker parts make an otherwise current release rebuild" do
    root = fake_repo()
    seed_ready_release(root)
    worker_dir = Path.join(root, "src/browser/layout/worker")
    File.mkdir_p!(worker_dir)
    worker = Path.join(worker_dir, "00-limits-and-messages.js")
    File.write!(worker, "changed worker")
    File.touch!(worker, {{2099, 1, 1}, {0, 0, 0}})
    npm_log = Path.join(root, "npm.log")

    {_out, 0} = run_shim(["__ensure-build"], build_env(root, npm_log))

    assert File.read!(npm_log) =~ "npm run vendor:elk -- --check"
  end

  test "distribution build generates checked assets while stdout contains only the release path" do
    root = fake_repo()
    repo = Path.expand("../..", __DIR__)

    for file <- ["packaging/scripts/build-release.sh", "scripts/lib/layout-assets.sh"] do
      destination = Path.join(root, file)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(Path.join(repo, file), destination)
    end

    bin = Path.join(root, "tools")
    File.mkdir_p!(bin)

    for tool <- ["npm", "mix"] do
      file = Path.join(bin, tool)
      File.write!(file, "#!/usr/bin/env bash\nexec \"$AIUR_FAKE_TOOLCHAIN\" exec -- #{tool} \"$@\"\n")
      File.chmod!(file, 0o755)
    end

    npm_log = Path.join(root, "npm.log")
    env = [{"PATH", bin <> ":" <> System.get_env("PATH")}, {"AIUR_FAKE_TOOLCHAIN", fake_mise()}, {"AIUR_FAKE_NPM_LOG", npm_log}, {"MIX_ENV", "dev"}]
    {out, 0} = System.cmd("bash", [Path.join(root, "packaging/scripts/build-release.sh")], env: env)

    assert out == Path.join(root, "src/_build/dev/rel/aiur") <> "\n"
    assert File.read!(npm_log) == "npm ci --ignore-scripts\nnpm run vendor:elk -- --check\n"
    assert File.read!(asset_path(root)) == "generated\n"
  end

  defp build_env(root, npm_log), do: [{"AIUR_REPO_ROOT", root}, {"AIUR_MISE_BIN", fake_mise()}, {"AIUR_FAKE_NPM_LOG", npm_log}, {"TMUX", nil}]
  defp asset_path(root), do: Path.join(root, "src/priv/static/vendor/elk/0.11.1/elk-worker.min.js")
  defp before?(text, first, second), do: elem(:binary.match(text, first), 0) < elem(:binary.match(text, second), 0)
end
