defmodule Aiur.Gateway.StateMigrationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.Config.Paths
  alias Aiur.Gateway.StateMigration
  alias Aiur.Gateway.StateMigrationCli

  @gw "gw-0123456789"

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "state")
    home = Path.join(tmp, "home")
    File.mkdir_p!(root)
    File.mkdir_p!(home)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(tmp) end)
    {:ok, root: root, home: home, tmp: tmp}
  end

  # A project whose legacy key is sha256(realpath(project root))[0:10], like the launcher's.
  defp project(tmp, repo) do
    dir = Path.join([tmp, "repos", String.replace(repo, "/", "_")])
    File.mkdir_p!(Path.join(dir, ".aiur"))
    key = :sha256 |> :crypto.hash(dir |> Path.expand() |> real()) |> Base.encode16(case: :lower) |> binary_part(0, 10)
    {%{repo: repo, config: Path.join([dir, ".aiur", "config"])}, key}
  end

  defp real(path), do: "realpath" |> System.cmd([path]) |> elem(0) |> String.trim_trailing("\n")

  defp seed(root, key, leaf, body \\ "x") do
    File.mkdir_p!(Path.join([root, key, leaf]))
    File.write!(Path.join([root, key, leaf, "file"]), body)
  end

  defp opts(ctx, extra \\ []), do: Keyword.merge([state_root: ctx.root, gateway_key: @gw, home: ctx.home], extra)

  defp tree(root) do
    for p <- Path.wildcard(Path.join(root, "**"), match_dot: true), into: %{} do
      {p, {File.read_link(p), File.regular?(p) && File.read!(p)}}
    end
  end

  defp plan_for(ctx, projects), do: StateMigration.plan(projects, opts(ctx))

  test "dry run lists each move and changes nothing", ctx do
    {a, ka} = project(ctx.tmp, "o/a")
    {b, kb} = project(ctx.tmp, "o/b")
    seed(ctx.root, ka, "a")
    seed(ctx.root, kb, "b")
    before = tree(ctx.root)

    out = capture_io(fn -> assert 0 = StateMigrationCli.main([], opts(ctx, projects: [a, b], gateway_key: @gw)) end)

    assert out =~ "move #{ctx.root}/#{ka}/a -> #{ctx.root}/#{@gw}/a"
    assert out =~ "move #{ctx.root}/#{kb}/b -> #{ctx.root}/#{@gw}/b"
    assert tree(ctx.root) == before
  end

  test "apply moves state, leaves a symlink, and rollback still resolves", ctx do
    {a, ka} = project(ctx.tmp, "o/a")
    seed(ctx.root, ka, "a", "kept")

    capture_io(fn -> assert 0 = StateMigrationCli.main(["--apply"], opts(ctx, projects: [a], live?: fn -> false end)) end)

    assert File.read!(Path.join([ctx.root, @gw, "a", "file"])) == "kept"
    assert File.read_link!(Path.join([ctx.root, ka, "a"])) == Path.join([ctx.root, @gw, "a"])
    assert File.read!(Path.join([ctx.root, ka, "a", "file"])) == "kept"
  end

  test "apply twice: the second run is a no-op", ctx do
    {a, ka} = project(ctx.tmp, "o/a")
    seed(ctx.root, ka, "a")
    args = [projects: [a], live?: fn -> false end]
    capture_io(fn -> 0 = StateMigrationCli.main(["--apply"], opts(ctx, args)) end)
    after_first = tree(ctx.root)

    out = capture_io(fn -> assert 0 = StateMigrationCli.main(["--apply"], opts(ctx, args)) end)

    assert out =~ "already_migrated o/a"
    assert tree(ctx.root) == after_first
  end

  test "a live daemon refuses apply and moves nothing", ctx do
    {a, ka} = project(ctx.tmp, "o/a")
    seed(ctx.root, ka, "a")
    before = tree(ctx.root)

    capture_io(:stderr, fn ->
      capture_io(fn -> assert 75 = StateMigrationCli.main(["--apply"], opts(ctx, projects: [a], live?: fn -> true end)) end)
    end)

    assert tree(ctx.root) == before
  end

  test "a conflict blocks apply for every project", ctx do
    {a, ka} = project(ctx.tmp, "o/a")
    {b, kb} = project(ctx.tmp, "o/b")
    seed(ctx.root, ka, "a")
    seed(ctx.root, @gw, "a")
    seed(ctx.root, kb, "b")
    before = tree(ctx.root)

    assert [%{kind: :conflict}, %{kind: :move}] = plan_for(ctx, [a, b])

    capture_io(:stderr, fn ->
      capture_io(fn -> assert 1 = StateMigrationCli.main(["--apply"], opts(ctx, projects: [a, b], live?: fn -> false end)) end)
    end)

    assert tree(ctx.root) == before
  end

  test "projects sharing a downcased leaf collide, whatever the case", ctx do
    {a, ka} = project(ctx.tmp, "o1/app")
    {b, kb} = project(ctx.tmp, "o2/App")
    seed(ctx.root, ka, "app")
    seed(ctx.root, kb, "App")

    assert [%{kind: :conflict, detail: d1}, %{kind: :conflict}] = plan_for(ctx, [a, b])
    assert d1 =~ "o1/app and o2/App"
  end

  test "destination leaf is downcased and rollback keeps the old case", ctx do
    {a, ka} = project(ctx.tmp, "Owner/MyRepo")
    seed(ctx.root, ka, "MyRepo")

    rows = plan_for(ctx, [a])
    assert Enum.any?(rows, &(&1.kind == :move and &1.dst == Path.join([ctx.root, @gw, "myrepo"])))
    assert :ok = StateMigration.apply_plan(rows, fn -> false end)

    assert File.dir?(Path.join([ctx.root, @gw, "myrepo"]))
    assert File.read_link!(Path.join([ctx.root, ka, "MyRepo"])) == Path.join([ctx.root, @gw, "myrepo"])
    assert Paths.sanitize("myrepo") == "myrepo"
  end

  test "mixed-case directory already under the gateway key is renamed in place, with no symlink", ctx do
    {a, key} = project(ctx.tmp, "O/MyRepo")
    seed(ctx.root, key, "MyRepo", "kept")

    rows = StateMigration.plan([a], opts(ctx, gateway_key: key))
    assert [%{kind: :move, src: src, dst: dst}] = rows
    assert src == Path.join([ctx.root, key, "MyRepo"])
    assert :ok = StateMigration.apply_plan(rows, fn -> false end)

    assert File.ls!(Path.join(ctx.root, key)) == ["myrepo"]
    assert File.read!(Path.join(dst, "file")) == "kept"
  end

  test "two directories differing only in case are a conflict", ctx do
    {a, ka} = project(ctx.tmp, "o/MyRepo")
    seed(ctx.root, ka, "myrepo")
    seed(ctx.root, ka, "MyRepo")

    assert [%{kind: :conflict, detail: d}] = plan_for(ctx, [a])
    assert d =~ "MyRepo" and d =~ "myrepo"
  end

  test "a global-config project is skipped without --from-key and moved with it", ctx do
    File.mkdir_p!(Path.join(ctx.home, ".aiur"))
    global = %{repo: "o/g", config: Path.join([ctx.home, ".aiur", "config"])}
    seed(ctx.root, "abcdef0123", "g")

    assert [%{kind: :skipped}] = plan_for(ctx, [global])
    assert [%{kind: :move, src: src}] = StateMigration.plan([global], opts(ctx, from_key: "abcdef0123"))
    assert src == Path.join([ctx.root, "abcdef0123", "g"])
  end

  test "only streamdeck settings are carried over; the secret and overrides are listed as not migrated", ctx do
    {a, ka} = project(ctx.tmp, "o/a")
    seed(ctx.root, ka, "a")
    inst = Path.join([ctx.home, ".aiur", "instances", ka])
    File.mkdir_p!(inst)
    for f <- ~w(streamdeck-settings.json secret_key_base config-overrides.json), do: File.write!(Path.join(inst, f), f)

    rows = plan_for(ctx, [a])
    assert Enum.count(rows, &(&1.kind == :not_migrated)) == 2
    assert :ok = StateMigration.apply_plan(rows, fn -> false end)

    assert File.ls!(Path.join([ctx.home, ".aiur", "instances", @gw])) == ["streamdeck-settings.json"]
  end

  test "not in gateway mode is a usage error", ctx do
    capture_io(:stderr, fn -> assert 64 = StateMigrationCli.main([], opts(ctx, projects: [], gateway_key: "abcdef0123")) end)
  end
end
