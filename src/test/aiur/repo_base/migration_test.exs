defmodule Aiur.RepoBase.MigrationTest do
  use Aiur.RepoBaseCase

  alias Aiur.{Asks, Findings}

  describe "refresh/3 legacy layout migration" do
    test "migrates an existing clone down to latest and leaves sidecars at the repo node", %{origin: origin, node: node, base: base} do
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, node])
      File.write!(Path.join(node, ".aiur-base-built"), "")
      File.mkdir_p!(Path.join(node, ".aiur-hex"))
      File.write!(Path.join(node, ".aiur-hex/cache"), "warm")
      File.write!(Path.join(node, "latest"), "legacy tracked path")

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch rebuilt_after_migration")

      assert File.dir?(Path.join(base, ".git"))
      refute File.dir?(Path.join(node, ".git"))
      assert File.read!(Path.join(base, "latest")) == "legacy tracked path"
      assert File.exists?(Path.join(node, ".aiur-hex/cache"))
      refute File.exists?(Path.join(base, ".aiur-hex/cache"))
      refute File.exists?(Path.join(base, ".aiur-base-built"))
      assert File.exists?(Path.join(base, "rebuilt_after_migration"))
    end

    test "keeps mixed tracked state-shaped application directories in the migrated clone", %{origin: origin, node: node, base: base, tmp: tmp} do
      repo = "https://github.com/owner/project.git"
      previous_root = Application.get_env(:aiur, :repo_base_root)
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, node])
      git!(["-C", node, "config", "user.email", "test@example.com"])
      git!(["-C", node, "config", "user.name", "Test"])

      tracked_paths = [
        {"builds/application.md", "tracked build source\n"},
        {"analytics/application.md", "tracked analytics source\n"},
        {"meta/findings.ndjson", "tracked application ledger\n"}
      ]

      Enum.each(tracked_paths, fn {path, contents} ->
        destination = Path.join(node, path)
        File.mkdir_p!(Path.dirname(destination))
        File.write!(destination, contents)
      end)

      git!(["-C", node, "add", "builds", "analytics", "meta"])
      git!(["-C", node, "commit", "--quiet", "-m", "application paths"])

      untracked_paths = [
        {"builds/packs/legacy.json", "state build\n"},
        {"analytics/runs/legacy.json", "state analytics\n"},
        {"meta/retros/legacy.md", "state retrospective\n"}
      ]

      Enum.each(untracked_paths, fn {path, contents} ->
        destination = Path.join(node, path)
        File.mkdir_p!(Path.dirname(destination))
        File.write!(destination, contents)
      end)

      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "repo"))

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      assert :ok = RepoBase.ensure_state_tree(repo)
      assert File.dir?(Path.join(base, ".git"))

      for {path, contents} <- tracked_paths do
        assert File.read!(Path.join(base, path)) == contents

        if path == "meta/findings.ndjson" do
          assert File.read!(RepoBase.findings_path(repo)) == ""
        else
          refute File.exists?(Path.join(RepoBase.repo_path(repo), path))
        end
      end

      for {path, contents} <- untracked_paths do
        assert File.read!(Path.join(base, path)) == contents
        refute File.exists?(Path.join(RepoBase.repo_path(repo), path))
      end
    end

    test "leaves untracked state symlinks in the migrated clone without traversing their targets", %{origin: origin, node: node, base: base, tmp: tmp} do
      repo = "https://github.com/owner/project.git"
      outside = Path.join(tmp, "outside")
      previous_root = Application.get_env(:aiur, :repo_base_root)
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, node])
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "sentinel"), "outside state\n")
      assert :ok = File.ln_s(outside, Path.join(node, "analytics"))
      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "repo"))

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      assert :ok = RepoBase.ensure_state_tree(repo)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(base, "analytics"))
      assert File.read!(Path.join(outside, "sentinel")) == "outside state\n"
      refute File.exists?(Path.join(RepoBase.analytics_path(repo), "sentinel"))
    end

    test "rejects a symlinked legacy state node before mutating its external target", %{
      origin: origin,
      node: node,
      base: base,
      tmp: tmp
    } do
      outside = Path.join(tmp, "outside-node")
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, outside])
      File.mkdir_p!(Path.join(outside, "analytics"))
      File.write!(Path.join(outside, "analytics/sentinel"), "external analytics\n")
      assert :ok = File.ln_s(outside, node)

      assert {:error, {:repo_base_state_path_symlink, ^node}} =
               RepoBase.refresh(base, origin, "true")

      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(node)
      assert File.read!(Path.join(outside, "analytics/sentinel")) == "external analytics\n"
      refute Path.wildcard(node <> ".migrating-*") != []
    end

    test "preserves an untracked nested state symlink without traversing its target", %{origin: origin, node: node, base: base, tmp: tmp} do
      repo = "https://github.com/owner/project.git"
      outside = Path.join(tmp, "outside")
      previous_root = Application.get_env(:aiur, :repo_base_root)
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, node])
      File.mkdir_p!(Path.join(node, "analytics/runs"))
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "sentinel"), "outside state\n")
      assert :ok = File.ln_s(outside, Path.join(node, "analytics/runs/external"))
      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "repo"))

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      assert :ok = RepoBase.ensure_state_tree(repo)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(base, "analytics/runs/external"))
      assert File.read!(Path.join(outside, "sentinel")) == "outside state\n"
      assert File.dir?(RepoBase.analytics_path(repo))
      refute File.exists?(Path.join(RepoBase.analytics_path(repo), "runs/external/sentinel"))
    end

    test "refuses a canonical state symlink during resumed migration", %{origin: origin, node: node, base: base, tmp: tmp} do
      parked = node <> ".migrating-interrupted"
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, parked])
      File.mkdir_p!(Path.join(parked, "meta"))
      File.write!(Path.join([parked, "meta", "findings.ndjson"]), Jason.encode!(finding("legacy")))
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "sentinel"), "outside state\n")
      File.mkdir_p!(node)
      assert :ok = File.ln_s(outside, Path.join(node, "meta"))

      assert {:error, {:repo_base_migration_recovery_failed, {:repo_base_state_path_symlink, _}}} =
               RepoBase.refresh(base, origin, "true")

      assert File.read!(Path.join(outside, "sentinel")) == "outside state\n"
      refute File.exists?(Path.join(outside, "findings.ndjson"))
    end

    test "migrates a legacy clone before importing its retrospective into canonical meta", %{
      origin: origin,
      node: node,
      base: base,
      tmp: tmp
    } do
      previous_root = Application.get_env(:aiur, :repo_base_root)
      source_root = Path.join(tmp, "legacy-source")
      repo = "https://github.com/owner/project.git"

      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, node])
      File.mkdir_p!(Path.join([node, "builds", "legacy-pack"]))
      File.mkdir_p!(Path.join([node, "analytics", "runs", "legacy-boot"]))
      File.mkdir_p!(Path.join([node, "meta", "retros"]))
      File.write!(Path.join([node, "builds", "legacy-pack", "pack.json"]), "legacy build\n")
      File.write!(Path.join([node, "analytics", "runs", "legacy-boot", "run-summary.json"]), "legacy analytics\n")
      legacy_finding = Jason.encode!(finding("legacy-finding")) <> "\n"
      File.write!(Path.join([node, "meta", "findings.ndjson"]), legacy_finding)
      File.write!(Path.join([node, "meta", "retros", "preexisting.md"]), "legacy retrospective\n")
      File.write!(Path.join(node, "base-record.json"), "legacy base record\n")
      File.mkdir_p!(Path.join([source_root, "docs", "executor"]))
      File.write!(Path.join([source_root, "docs", "executor", "hourly-retrospectives.md"]), "legacy notes\n")
      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "repo"))

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      assert :ok = RepoBase.setup_state(repo, source_root)
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "true")

      assert File.dir?(base)
      assert [imported] = Path.wildcard(Path.join(RepoBase.retros_path(repo), "legacy-*.md"))
      assert File.read!(imported) == "legacy notes\n"
      assert File.read!(Path.join(RepoBase.builds_path(repo), "legacy-pack/pack.json")) == "legacy build\n"
      assert File.read!(Path.join(RepoBase.analytics_path(repo), "runs/legacy-boot/run-summary.json")) == "legacy analytics\n"
      assert File.read!(RepoBase.findings_path(repo)) == legacy_finding
      assert File.read!(Path.join(RepoBase.retros_path(repo), "preexisting.md")) == "legacy retrospective\n"
      assert File.exists?(Path.join(RepoBase.repo_path(repo), "base-record.json"))
      refute File.exists?(Path.join(base, "base-record.json"))

      for path <- ["builds", "analytics", "meta"] do
        refute File.exists?(Path.join(base, path)), "#{path} was stranded inside latest"
      end
    end

    test "merges state left by an interrupted legacy migration", %{origin: origin, node: node, base: base, tmp: tmp} do
      parked = node <> ".migrating-interrupted"
      previous_root = Application.get_env(:aiur, :repo_base_root)
      current_finding = Jason.encode!(finding("current"))
      legacy_finding = Jason.encode!(finding("legacy"))
      current_ask = Jason.encode!(operator_ask("ask_current", "Current operator request"))
      legacy_ask = Jason.encode!(operator_ask("ask_legacy", "Legacy operator request"))
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, parked])
      File.mkdir_p!(Path.join([parked, "builds", "legacy-pack"]))
      File.mkdir_p!(Path.join([parked, "analytics", "runs", "legacy"]))
      File.mkdir_p!(Path.join([parked, "analytics", "runs", "current"]))
      File.mkdir_p!(Path.join([parked, "meta", "retros"]))
      File.write!(Path.join([parked, "builds", "legacy-pack", "pack.json"]), "legacy build\n")
      File.write!(Path.join([parked, "analytics", "runs", "legacy", "summary.json"]), "legacy analytics\n")
      File.write!(Path.join([parked, "analytics", "runs", "current", "summary.json"]), "legacy collision\n")
      File.write!(Path.join([parked, "meta", "findings.ndjson"]), legacy_finding)
      File.write!(Path.join([parked, "meta", "asks.ndjson"]), legacy_ask)
      File.write!(Path.join([parked, "meta", "retros", "legacy.md"]), "legacy retrospective\n")

      File.mkdir_p!(Path.join([node, "builds", "current-pack"]))
      File.mkdir_p!(Path.join([node, "analytics", "runs", "current"]))
      File.mkdir_p!(Path.join([node, "meta", "retros"]))
      File.write!(Path.join([node, "builds", "current-pack", "pack.json"]), "current build\n")
      File.write!(Path.join([node, "analytics", "runs", "current", "summary.json"]), "current analytics\n")
      File.write!(Path.join([node, "meta", "findings.ndjson"]), current_finding)
      File.write!(Path.join([node, "meta", "asks.ndjson"]), current_ask)
      File.write!(Path.join([node, "meta", "retros", "current.md"]), "current retrospective\n")
      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "repo"))

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "true")

      assert File.read!(Path.join([node, "builds", "legacy-pack", "pack.json"])) == "legacy build\n"
      assert File.read!(Path.join([node, "builds", "current-pack", "pack.json"])) == "current build\n"
      assert File.read!(Path.join([node, "analytics", "runs", "legacy", "summary.json"])) == "legacy analytics\n"
      assert File.read!(Path.join([node, "analytics", "runs", "current", "summary.json"])) == "current analytics\n"
      assert [collision] = Path.wildcard(Path.join([node, "analytics", "runs", "current", "summary.json.migrated-*"]))
      assert File.read!(collision) == "legacy collision\n"
      assert File.read!(Path.join([node, "meta", "retros", "legacy.md"])) == "legacy retrospective\n"
      assert File.read!(Path.join([node, "meta", "retros", "current.md"])) == "current retrospective\n"

      assert File.read!(Path.join([node, "meta", "findings.ndjson"])) == current_finding <> "\n" <> legacy_finding <> "\n"
      assert {:ok, [current, legacy]} = Findings.all()
      assert Enum.map([current, legacy], & &1["slug"]) == ["current", "legacy"]

      assert {:ok, asks} = Asks.all("owner/project")
      assert Enum.map(asks, & &1["id"]) == ["ask_current", "ask_legacy"]
    end
  end
end
