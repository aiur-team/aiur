defmodule Aiur.TestToolDownloadTest do
  use ExUnit.Case, async: true

  test "test npm children reject uncached packages without contacting a registry" do
    cache = Aiur.TestSupport.tmp_root!("offline-npm-cache")
    on_exit(fn -> File.rm_rf!(cache) end)

    {output, status} =
      System.cmd("npm", ["exec", "--yes", "--package=aiur-test-never-cached-package", "--", "missing-command"],
        stderr_to_stdout: true,
        env: [
          {"npm_config_cache", cache},
          {"npm_config_registry", "http://127.0.0.1:1"},
          {"npm_config_fetch_retries", "0"}
        ]
      )

    assert status != 0
    assert output =~ "ENOTCACHED"
    refute File.exists?(Path.join(cache, "_npx"))
  end
end
