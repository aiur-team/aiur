defmodule Aiur.RunTelemetry.AnalyticsToolsTest do
  use ExUnit.Case, async: true
  alias Aiur.RunTelemetry.{AnalyticsTools, Summaries}

  setup do
    root = Aiur.TestSupport.tmp_root!("analytics-tools")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    opts = Enum.map([:checkout, :release_root, :cwd], &{&1, Path.join(root, Atom.to_string(&1))})
    %{root: root, opts: opts}
  end

  test "release copy serves consumer repos; checkout wins, then cwd, then missing", %{opts: opts} do
    release = Path.join(opts[:release_root], "analytics")
    checkout = Path.join(opts[:checkout], "analytics")
    cwd = Path.join(opts[:cwd], "analytics")
    File.mkdir_p!(release)
    File.mkdir_p!(cwd)
    assert AnalyticsTools.resolve(nil, opts) == {:ok, release}
    File.mkdir_p!(checkout)
    assert AnalyticsTools.resolve(nil, opts) == {:ok, checkout}
    Aiur.TestCleanup.rm_rf!(checkout)
    Aiur.TestCleanup.rm_rf!(release)
    assert AnalyticsTools.resolve(nil, opts) == {:ok, cwd}
    Aiur.TestCleanup.rm_rf!(cwd)
    assert AnalyticsTools.resolve(nil, opts) == {:error, :reduce_dir_not_found}
  end

  test "explicit override wins even before the directory exists", %{opts: opts, root: root} do
    File.mkdir_p!(Path.join(opts[:checkout], "analytics"))
    assert AnalyticsTools.resolve(root, opts) == {:ok, root}
    assert Summaries.reduce_dir(root) == {:ok, root}
  end

  test "release step ships executable wrappers, libraries and schemas without fixtures", %{root: root} do
    release = %{path: root}
    assert Aiur.MixProject.copy_analytics(release) == release
    assert File.regular?(Path.join(root, "analytics/lib/analytics/stats/__init__.py"))
    assert File.regular?(Path.join(root, "analytics/schema/experiment-result.v1.json"))
    assert {_, 0} = System.cmd(Path.join(root, "analytics/experiment-stats"), ["--help"], env: [{"PYTHONDONTWRITEBYTECODE", "1"}])
    refute File.exists?(Path.join(root, "analytics/tests"))
    assert Path.wildcard(Path.join(root, "analytics/**/__pycache__")) == []
  end

  test "release step refuses unsafe release paths before deleting anything" do
    source = Path.expand("../../../../analytics/experiment-stats", __DIR__)
    assert File.regular?(source)

    for path <- ["", "..", "analytics", "/", Path.expand("../../../..", __DIR__)] do
      assert_raise ArgumentError, ~r/unsafe release path/, fn -> Aiur.MixProject.copy_analytics(%{path: path}) end
    end

    assert File.regular?(source)
  end
end
