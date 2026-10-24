defmodule Aiur.BrowserHarness.BaseNavigation do
  @moduledoc false

  def workflow_path(default) do
    if System.get_env("AIUR_BROWSER_FIXTURE_MODE") == "base-navigation" do
      path = Path.join(System.tmp_dir!(), "browser-base-navigation-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}.yaml")
      File.write!(path, File.read!(default) <> "\nexperiments:\n  enabled: false\n")
      System.at_exit(fn _ -> Aiur.TestCleanup.rm_rf!(path) end)
      path
    else
      default
    end
  end
end
