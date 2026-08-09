defmodule Aiur.RepoBaseTest do
  # async: false — refresh/3 broadcasts on the global "prewarm:phase" topic, so
  # the phase-event test must not race other tests emitting on the same topic.
  use ExUnit.Case, async: false

  alias Aiur.{Asks, Findings, RepoBase}

  setup do
    tmp = Path.join(System.tmp_dir!(), "aiur_rb_#{System.unique_integer([:positive])}")
    origin = Path.join(tmp, "origin")
    node = Path.join(tmp, "repo/owner/project")
    base = Path.join(node, "latest")
    File.mkdir_p!(origin)

    git!(["init", "--quiet", "-b", "main", origin])
    git!(["-C", origin, "config", "user.email", "test@example.com"])
    git!(["-C", origin, "config", "user.name", "Test"])
    File.write!(Path.join(origin, "README.md"), "v1\n")
    git!(["-C", origin, "add", "."])
    git!(["-C", origin, "commit", "--quiet", "-m", "init"])

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp, origin: origin, node: node, base: base}
  end

  describe "refresh/3" do
    test "clones and builds on first refresh, writing a SHA-keyed base record beside latest", %{origin: origin, node: node, base: base} do
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")

      assert File.exists?(Path.join(base, "built_ran")), "base_build command did not run"
      assert {:ok, record_body} = File.read(Path.join(node, "base-record.json"))
      assert {:ok, record} = Jason.decode(record_body)
      assert record["clone_head"] == head(origin)
      assert is_binary(record["prewarm_script_hash"])
      assert is_binary(record["built_at"])
      refute File.exists?(Path.join(base, ".aiur-base-built"))
      assert head(base) == head(origin)
    end

    test "rebuilds when the prewarm script changes without a new commit", %{origin: origin, base: base} do
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch first_build")
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch second_build")

      assert File.exists?(Path.join(base, "second_build"))
    end

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

    test "rejects semantically invalid asks while merging a legacy ledger", %{origin: origin, node: node, base: base, tmp: tmp} do
      parked = node <> ".migrating-interrupted"
      previous_root = Application.get_env(:aiur, :repo_base_root)
      destination = Path.join([node, "meta", "asks.ndjson"])
      source = Path.join([parked, "meta", "asks.ndjson"])
      current = Jason.encode!(operator_ask("ask_current", "Current ask")) <> "\n"
      invalid = Jason.encode!(%{"id" => "ask_invalid", "status" => "open"}) <> "\n"

      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, parked])
      File.mkdir_p!(Path.dirname(source))
      File.mkdir_p!(Path.dirname(destination))
      File.write!(source, invalid)
      File.write!(destination, current)
      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "repo"))

      on_exit(fn ->
        if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
      end)

      assert {:error, {:repo_base_migration_recovery_failed, {:invalid_asks_ledger, ^source, 1}}} =
               RepoBase.refresh(base, origin, "true")

      assert File.read!(source) == invalid
      assert File.read!(destination) == current
    end

    test "rejects overlapping ask IDs while merging a legacy ledger", %{origin: origin, node: node, base: base, tmp: tmp} do
      parked = node <> ".migrating-interrupted"
      previous_root = Application.get_env(:aiur, :repo_base_root)
      destination = Path.join([node, "meta", "asks.ndjson"])
      source = Path.join([parked, "meta", "asks.ndjson"])
      current = Jason.encode!(operator_ask("ask_duplicate", "Current ask")) <> "\n"
      legacy = Jason.encode!(operator_ask("ask_duplicate", "Legacy ask")) <> "\n"

      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, parked])
      File.mkdir_p!(Path.dirname(source))
      File.mkdir_p!(Path.dirname(destination))
      File.write!(source, legacy)
      File.write!(destination, current)
      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "repo"))

      on_exit(fn ->
        if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
      end)

      assert {:error, {:repo_base_migration_recovery_failed, {:invalid_asks_ledger, ^destination, 2}}} =
               RepoBase.refresh(base, origin, "true")

      assert File.read!(source) == legacy
      assert File.read!(destination) == current
    end

    test "finishes a findings transfer once after a crash following its atomic replacement", %{origin: origin, node: node, base: base, tmp: tmp} do
      parked = node <> ".migrating-interrupted"
      previous_root = Application.get_env(:aiur, :repo_base_root)
      current = Jason.encode!(finding("current")) <> "\n"
      legacy = Jason.encode!(finding("legacy")) <> "\n"
      destination = Path.join([node, "meta", "findings.ndjson"])
      source = Path.join([parked, "meta", "findings.ndjson"])
      marker = destination <> ".migration-transfer"
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, parked])
      File.mkdir_p!(Path.dirname(source))
      File.mkdir_p!(Path.dirname(destination))
      File.write!(source, legacy)
      File.write!(destination, current <> legacy)

      File.write!(
        marker,
        Jason.encode!(%{
          "source" => source,
          "source_hash" => :crypto.hash(:sha256, legacy) |> Base.encode16(case: :lower),
          "destination" => destination,
          "destination_hash" => :crypto.hash(:sha256, current) |> Base.encode16(case: :lower),
          "merged_hash" => :crypto.hash(:sha256, current <> legacy) |> Base.encode16(case: :lower)
        })
      )

      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "repo"))

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "true")
      assert File.read!(destination) == current <> legacy
      refute File.exists?(marker)
    end

    test "retries a findings transfer when recovery finds its checkpoint before replacement", %{origin: origin, node: node, base: base, tmp: tmp} do
      parked = node <> ".migrating-interrupted"
      previous_root = Application.get_env(:aiur, :repo_base_root)
      current = Jason.encode!(finding("current")) <> "\n"
      legacy = Jason.encode!(finding("legacy")) <> "\n"
      destination = Path.join([node, "meta", "findings.ndjson"])
      source = Path.join([parked, "meta", "findings.ndjson"])
      marker = destination <> ".migration-transfer"
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, parked])
      File.mkdir_p!(Path.dirname(source))
      File.mkdir_p!(Path.dirname(destination))
      File.write!(source, legacy)
      File.write!(destination, current)

      File.write!(
        marker,
        Jason.encode!(%{
          "source" => source,
          "source_hash" => :crypto.hash(:sha256, legacy) |> Base.encode16(case: :lower),
          "destination" => destination,
          "destination_hash" => :crypto.hash(:sha256, current) |> Base.encode16(case: :lower),
          "merged_hash" => :crypto.hash(:sha256, current <> legacy) |> Base.encode16(case: :lower)
        })
      )

      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "repo"))

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "true")
      assert File.read!(destination) == current <> legacy
      refute File.exists?(source)
      refute File.exists?(marker)
    end

    test "clears findings and asks checkpoints after source removal without another merge", %{origin: origin, node: node, base: base, tmp: tmp} do
      parked = node <> ".migrating-interrupted"
      previous_root = Application.get_env(:aiur, :repo_base_root)
      current = Jason.encode!(finding("current")) <> "\n"
      legacy = Jason.encode!(finding("legacy")) <> "\n"
      destination = Path.join([node, "meta", "findings.ndjson"])
      source = Path.join([parked, "meta", "findings.ndjson"])
      marker = destination <> ".migration-transfer"
      asks_destination = Path.join([node, "meta", "asks.ndjson"])
      asks_source = Path.join([parked, "meta", "asks.ndjson"])
      asks_marker = asks_destination <> ".asks-migration-transfer"
      current_ask = Jason.encode!(operator_ask("ask_current", "Current ask")) <> "\n"
      legacy_ask = Jason.encode!(operator_ask("ask_legacy", "Legacy ask")) <> "\n"
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, parked])
      File.mkdir_p!(Path.dirname(source))
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, current <> legacy)
      File.write!(asks_destination, current_ask <> legacy_ask)

      File.write!(
        marker,
        Jason.encode!(%{
          "source" => source,
          "source_hash" => :crypto.hash(:sha256, legacy) |> Base.encode16(case: :lower),
          "destination" => destination,
          "destination_hash" => :crypto.hash(:sha256, current) |> Base.encode16(case: :lower),
          "merged_hash" => :crypto.hash(:sha256, current <> legacy) |> Base.encode16(case: :lower)
        })
      )

      File.write!(
        asks_marker,
        Jason.encode!(%{
          "source" => asks_source,
          "source_hash" => :crypto.hash(:sha256, legacy_ask) |> Base.encode16(case: :lower),
          "destination" => asks_destination,
          "destination_hash" => :crypto.hash(:sha256, current_ask) |> Base.encode16(case: :lower),
          "merged_hash" => :crypto.hash(:sha256, current_ask <> legacy_ask) |> Base.encode16(case: :lower)
        })
      )

      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "repo"))

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "true")
      assert File.read!(destination) == current <> legacy
      assert File.read!(asks_destination) == current_ask <> legacy_ask
      refute File.exists?(marker)
      refute File.exists?(asks_marker)
    end

    test "rejects a transfer marker whose source is outside the parked clone", %{
      origin: origin,
      node: node,
      base: base,
      tmp: tmp
    } do
      parked = node <> ".migrating-interrupted"
      current = Jason.encode!(finding("current")) <> "\n"
      victim_contents = Jason.encode!(finding("victim")) <> "\n"
      destination = Path.join([node, "meta", "findings.ndjson"])
      expected_source = Path.join([parked, "meta", "findings.ndjson"])
      victim = Path.join(tmp, "external-victim.ndjson")
      marker = destination <> ".migration-transfer"
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, parked])
      File.mkdir_p!(Path.dirname(expected_source))
      File.mkdir_p!(Path.dirname(destination))
      File.write!(expected_source, victim_contents)
      File.write!(victim, victim_contents)
      File.write!(destination, current <> victim_contents)

      File.write!(
        marker,
        Jason.encode!(%{
          "source" => victim,
          "source_hash" => :crypto.hash(:sha256, victim_contents) |> Base.encode16(case: :lower),
          "destination" => destination,
          "destination_hash" => :crypto.hash(:sha256, current) |> Base.encode16(case: :lower),
          "merged_hash" => :crypto.hash(:sha256, current <> victim_contents) |> Base.encode16(case: :lower)
        })
      )

      assert {:error, {:repo_base_migration_recovery_failed, {:findings_transfer_recovery_failed, ^destination, :invalid_source}}} =
               RepoBase.refresh(base, origin, "true")

      assert File.read!(victim) == victim_contents
      assert File.read!(expected_source) == victim_contents
      assert File.exists?(marker)
    end

    test "rejects a transfer source reached through a parked-clone symlink", %{
      origin: origin,
      node: node,
      base: base,
      tmp: tmp
    } do
      parked = node <> ".migrating-interrupted"
      outside_meta = Path.join(tmp, "outside-meta")
      current = Jason.encode!(finding("current")) <> "\n"
      victim_contents = Jason.encode!(finding("victim")) <> "\n"
      destination = Path.join([node, "meta", "findings.ndjson"])
      source = Path.join([parked, "meta", "findings.ndjson"])
      victim = Path.join(outside_meta, "findings.ndjson")
      marker = destination <> ".migration-transfer"
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, parked])
      File.mkdir_p!(outside_meta)
      File.mkdir_p!(Path.dirname(destination))
      File.write!(victim, victim_contents)
      File.write!(destination, current <> victim_contents)
      assert :ok = File.ln_s(outside_meta, Path.join(parked, "meta"))

      File.write!(
        marker,
        Jason.encode!(%{
          "source" => source,
          "source_hash" => :crypto.hash(:sha256, victim_contents) |> Base.encode16(case: :lower),
          "destination" => destination,
          "destination_hash" => :crypto.hash(:sha256, current) |> Base.encode16(case: :lower),
          "merged_hash" => :crypto.hash(:sha256, current <> victim_contents) |> Base.encode16(case: :lower)
        })
      )

      assert {:error, {:repo_base_migration_recovery_failed, {:repo_base_state_path_symlink, _}}} =
               RepoBase.refresh(base, origin, "true")

      assert File.read!(victim) == victim_contents
      assert File.exists?(marker)
    end

    test "preserves both ledgers when a source changes after findings replacement", %{origin: origin, node: node, base: base} do
      parked = node <> ".migrating-interrupted"
      current = Jason.encode!(finding("current")) <> "\n"
      legacy = Jason.encode!(finding("legacy")) <> "\n"
      changed_legacy = legacy <> Jason.encode!(finding("new-observation")) <> "\n"
      destination = Path.join([node, "meta", "findings.ndjson"])
      source = Path.join([parked, "meta", "findings.ndjson"])
      marker = destination <> ".migration-transfer"
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, parked])
      File.mkdir_p!(Path.dirname(source))
      File.mkdir_p!(Path.dirname(destination))
      File.write!(source, changed_legacy)
      File.write!(destination, current <> legacy)

      File.write!(
        marker,
        Jason.encode!(%{
          "source" => source,
          "source_hash" => :crypto.hash(:sha256, legacy) |> Base.encode16(case: :lower),
          "destination" => destination,
          "destination_hash" => :crypto.hash(:sha256, current) |> Base.encode16(case: :lower),
          "merged_hash" => :crypto.hash(:sha256, current <> legacy) |> Base.encode16(case: :lower)
        })
      )

      assert {:error, {:repo_base_migration_recovery_failed, {:findings_transfer_recovery_failed, ^destination, :source_changed}}} =
               RepoBase.refresh(base, origin, "true")

      assert File.read!(destination) == current <> legacy
      assert File.read!(source) == changed_legacy
      assert File.exists?(marker)
    end

    test "leaves both ledgers intact when an interrupted migration has corrupt findings", %{origin: origin, node: node, base: base} do
      parked = node <> ".migrating-interrupted"
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, parked])
      File.mkdir_p!(Path.join(parked, "meta"))
      File.write!(Path.join([parked, "meta", "findings.ndjson"]), "{not-json}")

      File.mkdir_p!(Path.join(node, "meta"))
      destination = Path.join([node, "meta", "findings.ndjson"])
      File.write!(destination, Jason.encode!(finding("current")))

      assert {:error, {:repo_base_migration_recovery_failed, {:invalid_findings_ledger, _, 1}}} =
               RepoBase.refresh(base, origin, "true")

      assert File.read!(destination) == Jason.encode!(finding("current"))
      assert File.read!(Path.join([parked, "meta", "findings.ndjson"])) == "{not-json}"
    end

    test "leaves both ledgers intact when the canonical findings ledger is corrupt", %{origin: origin, node: node, base: base} do
      parked = node <> ".migrating-interrupted"
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, parked])
      File.mkdir_p!(Path.join(parked, "meta"))
      source = Path.join([parked, "meta", "findings.ndjson"])
      File.write!(source, Jason.encode!(finding("legacy")))

      File.mkdir_p!(Path.join(node, "meta"))
      destination = Path.join([node, "meta", "findings.ndjson"])
      File.write!(destination, "{\"scope\":\"host\"}")

      assert {:error, {:repo_base_migration_recovery_failed, {:invalid_findings_ledger, ^destination, 1}}} =
               RepoBase.refresh(base, origin, "true")

      assert File.read!(destination) == "{\"scope\":\"host\"}"
      assert File.read!(source) == Jason.encode!(finding("legacy"))
    end

    test "serializes recovery of a parked clone without a flock executable", %{origin: origin, node: node, base: base, tmp: tmp} do
      parked = node <> ".migrating-interrupted"
      repo = "https://github.com/owner/project.git"
      previous_root = Application.get_env(:aiur, :repo_base_root)
      previous_path = System.get_env("PATH")
      File.mkdir_p!(Path.dirname(node))
      git!(["clone", "--quiet", origin, parked])
      File.mkdir_p!(node)
      File.mkdir_p!(Path.join(node, ".aiur-mix"))
      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "repo"))
      System.put_env("PATH", "")

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end

        if previous_path, do: System.put_env("PATH", previous_path), else: System.delete_env("PATH")
      end)

      results =
        1..2
        |> Task.async_stream(fn _ -> RepoBase.ensure_state_tree(repo) end, max_concurrency: 2, ordered: false)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1 == :ok))
      assert File.dir?(Path.join(base, ".git"))
      refute File.exists?(parked)
    end

    test "serializes concurrent first finding appends through legacy migration", %{tmp: tmp, node: node} do
      previous_root = Application.get_env(:aiur, :repo_base_root)
      repo = "https://github.com/owner/project.git"
      File.mkdir_p!(Path.join(node, ".git"))
      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "repo"))

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      results =
        [finding("first-migration-one"), finding("first-migration-two")]
        |> Task.async_stream(&Findings.append(repo, &1), max_concurrency: 2, ordered: false)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1 == :ok))
      assert {:ok, ["first-migration-one", "first-migration-two"]} = Findings.slugs()
      assert File.dir?(Path.join(RepoBase.base_path(repo), ".git"))
      refute File.dir?(Path.join(RepoBase.repo_path(repo), ".git"))
      # The SQLite migration lease is the real cross-process lock: the file is
      # only created when with_migration_lock runs, so this is a non-vacuous
      # proof the lease was exercised, and both concurrent appends above
      # succeeding proves the exclusive transaction was released afterward.
      assert File.regular?(RepoBase.repo_path(repo) <> ".migration-lock.sqlite3")
    end

    test "is idempotent when main has not advanced", %{origin: origin, base: base} do
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      File.rm!(Path.join(base, "built_ran"))

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")

      refute File.exists?(Path.join(base, "built_ran")),
             "base_build re-ran even though main did not advance"
    end

    test "rebuilds when main advances", %{origin: origin, base: base} do
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      File.rm!(Path.join(base, "built_ran"))

      File.write!(Path.join(origin, "README.md"), "v2\n")
      git!(["-C", origin, "commit", "--quiet", "-am", "advance"])

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")

      assert File.exists?(Path.join(base, "built_ran")), "base_build did not re-run after advance"
      assert head(base) == head(origin)
    end

    test "tracks configured v2 and ignores a main-only advance", %{origin: origin, base: base, tmp: tmp} do
      git!(["-C", origin, "checkout", "-b", "v2"])
      File.write!(Path.join(origin, "README.md"), "v2 initial\n")
      git!(["-C", origin, "commit", "--quiet", "-am", "v2 initial"])
      v2_initial = head(origin)

      config = Path.join(tmp, "v2.aiurconfig")
      previous_config = Application.get_env(:aiur, :workflow_file_path)
      File.write!(config, "tracker:\n  kind: memory\n  base_branch: v2\n")
      Aiur.Workflow.set_workflow_file_path(config)

      on_exit(fn ->
        case previous_config do
          nil -> Aiur.Workflow.clear_workflow_file_path()
          path -> Aiur.Workflow.set_workflow_file_path(path)
        end
      end)

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      assert head(base) == v2_initial
      File.rm!(Path.join(base, "built_ran"))

      git!(["-C", origin, "checkout", "main"])
      File.write!(Path.join(origin, "README.md"), "main only\n")
      git!(["-C", origin, "commit", "--quiet", "-am", "main only"])

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      assert head(base) == v2_initial
      refute File.exists?(Path.join(base, "built_ran"))

      git!(["-C", origin, "checkout", "v2"])
      File.write!(Path.join(origin, "README.md"), "v2 advanced\n")
      git!(["-C", origin, "commit", "--quiet", "-am", "v2 advanced"])
      v2_advanced = head(origin)

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "touch built_ran")
      assert head(base) == v2_advanced
      assert File.exists?(Path.join(base, "built_ran"))
    end

    test "returns an error and skips the marker when base_build fails", %{origin: origin, base: base} do
      assert {:error, {:base_build_failed, status, _out}} = RepoBase.refresh(base, origin, "exit 3")
      assert status == 3
      refute File.exists?(Path.join(Path.dirname(base), "base-record.json"))
    end

    test "runs base_build with the base mise.toml trusted", %{origin: origin, base: base} do
      # base_build records the trust path it actually ran with; proves base_env/1
      # reached the build shell (regression for the untrusted-base prewarm hang).
      assert {:ok, ^base} =
               RepoBase.refresh(base, origin, ~s(printf '%s' "$MISE_TRUSTED_CONFIG_PATHS" > trust_path))

      assert File.read!(Path.join(base, "trust_path")) =~ base
    end

    test "prewarm build starts mise OTP and Hex with release launcher environment", %{
      tmp: tmp,
      origin: origin,
      node: node,
      base: base
    } do
      release_root = Path.join(tmp, "release")
      release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
      release_bin = Path.join(release_root, "bin")
      user_bin = Path.join(tmp, "toolchain/bin")
      expected_erl = System.find_executable("erl")
      File.mkdir_p!(release_erts_bin)
      File.mkdir_p!(release_bin)
      File.mkdir_p!(user_bin)
      File.write!(Path.join(release_erts_bin, "erl"), "#!/bin/sh\necho poisoned-release-erl\nexit 86\n")
      File.chmod!(Path.join(release_erts_bin, "erl"), 0o755)

      File.write!(
        Path.join(origin, "mix.exs"),
        """
        defmodule PrewarmFixture.MixProject do
          use Mix.Project

          def project, do: [app: :prewarm_fixture, version: "0.1.0"]
          def application, do: [extra_applications: [:inets]]
        end
        """
      )

      File.cp!(Path.expand("../../../mise.toml", __DIR__), Path.join(origin, "mise.toml"))

      git!(["-C", origin, "add", "mix.exs", "mise.toml"])
      git!(["-C", origin, "commit", "--quiet", "-m", "add prewarm fixture"])

      hex_archive =
        Mix.path_for(:archives)
        |> File.ls!()
        |> Enum.find(&String.starts_with?(&1, "hex-"))

      assert is_binary(hex_archive), "expected the test toolchain to provide a Hex archive"

      archive_dir = Path.join([node, ".aiur-mix", "archives"])
      File.mkdir_p!(archive_dir)

      File.cp_r!(
        Path.join(Mix.path_for(:archives), hex_archive),
        Path.join(archive_dir, hex_archive)
      )

      release_env = [
        {"AIUR_RELEASE_DIR", release_root},
        {"ROOTDIR", release_root},
        {"BINDIR", release_erts_bin},
        {"EMU", "beam"},
        {"PROGNAME", "erl"},
        {"PATH", Enum.join([release_erts_bin, release_bin, user_bin, System.fetch_env!("PATH")], ":")}
      ]

      previous_env =
        Map.new(release_env, fn {name, _value} ->
          {name, System.get_env(name)}
        end)

      Enum.each(release_env, fn {name, value} -> System.put_env(name, value) end)

      on_exit(fn ->
        Enum.each(previous_env, fn {name, value} ->
          if value, do: System.put_env(name, value), else: System.delete_env(name)
        end)
      end)

      assert {:ok, ^base} =
               RepoBase.refresh(
                 base,
                 origin,
                 ~S"""
                 mise exec -- mix hex.config >/dev/null && mise exec -- mix run --no-start -e '{:ok, _} = Application.ensure_all_started(:inets); erl = System.find_executable("erl"); inets = :code.lib_dir(:inets); if not is_binary(erl) or not is_list(inets), do: System.halt(41); File.write!("release_env_scrubbed", IO.iodata_to_binary([erl, "\n", inets, "\nhex-started"]))'
                 """
               )

      proof = File.read!(Path.join(base, "release_env_scrubbed"))
      assert proof =~ to_string(:code.lib_dir(:inets))
      assert [erl_path, _inets_path, "hex-started"] = String.split(proof, "\n")
      assert erl_path == expected_erl
    end

    test "keeps package-manager caches beside latest rather than in the clone", %{origin: origin, node: node, base: base} do
      command = ~s(mkdir -p "$HEX_HOME" "$MIX_HOME" "$npm_config_cache"; touch "$HEX_HOME/hex" "$MIX_HOME/mix" "$npm_config_cache/npm")

      assert {:ok, ^base} = RepoBase.refresh(base, origin, command)

      for cache <- [".aiur-hex/hex", ".aiur-mix/mix", ".aiur-npm-cache/npm"] do
        assert File.exists?(Path.join(node, cache))
        refute File.exists?(Path.join(base, cache))
      end
    end

    test "logs base_build failures at error with the captured output", %{origin: origin, base: base} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:base_build_failed, 3, _}} =
                   RepoBase.refresh(base, origin, "echo boom 1>&2; exit 3")
        end)

      assert log =~ "prewarm base unavailable"
      assert log =~ "boom"
    end

    test "does not log a prewarm error on a successful base_build", %{origin: origin, base: base} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, ^base} = RepoBase.refresh(base, origin, "true")
        end)

      refute log =~ "prewarm base unavailable"
    end

    test "never persists the auth header into the cloned repo's git config", %{origin: origin, base: base} do
      # The token rides in env-config (GIT_CONFIG_*), so it must never be written
      # into the cloned repo's own config the way a token-in-URL or `-c` would.
      assert {:ok, ^base} = RepoBase.refresh(base, origin, "true")

      config = File.read!(Path.join(base, ".git/config"))
      refute config =~ "extraheader"
      refute config =~ "Authorization"
      refute config =~ "x-access-token"
    end

    test "emits ordered phase events", %{origin: origin, base: base} do
      Phoenix.PubSub.subscribe(Aiur.PubSub, "prewarm:phase")

      assert {:ok, ^base} = RepoBase.refresh(base, origin, "true")

      assert_receive {:prewarm_phase, :cloning}, 5_000
      assert_receive {:prewarm_phase, :fetching}, 5_000
      assert_receive {:prewarm_phase, :building}, 5_000
      assert_receive {:prewarm_phase, :ready}, 5_000
    end
  end

  defp finding(slug) do
    %{
      "slug" => slug,
      "observed_at" => "2026-08-02T04:30:00Z",
      "scope" => "aiur",
      "observed_in" => "owner/project",
      "instance" => "boot-123",
      "summary" => "a concise observation",
      "evidence" => ["#1464"],
      "cost" => "one hour",
      "ticket" => nil,
      "status" => "open"
    }
  end

  defp operator_ask(id, title) do
    %{
      "id" => id,
      "title" => title,
      "body" => nil,
      "urgency" => "normal",
      "blocking" => false,
      "status" => "open",
      "created_at" => "2026-08-08T12:00:00Z",
      "created_by" => "executor"
    }
  end

  describe "base_path/1" do
    test "puts the base clone at <owner>/<name>/latest under the base root" do
      assert RepoBase.base_path("https://github.com/foo/bar.git") |> Path.split() |> Enum.take(-3) ==
               ["foo", "bar", "latest"]

      assert RepoBase.base_path("git@github.com:foo/bar.git") |> Path.split() |> Enum.take(-3) ==
               ["foo", "bar", "latest"]
    end

    test "keeps the build store beside latest in the repository state node" do
      assert RepoBase.builds_path("https://github.com/foo/bar.git") |> Path.split() |> Enum.take(-3) ==
               ["foo", "bar", "builds"]
    end

    test "exposes sibling meta and analytics state paths" do
      repo = "https://github.com/foo/bar.git"

      assert RepoBase.meta_path(repo) |> Path.split() |> Enum.take(-3) == ["foo", "bar", "meta"]
      assert RepoBase.findings_path(repo) |> Path.split() |> Enum.take(-4) == ["foo", "bar", "meta", "findings.ndjson"]
      assert RepoBase.retros_path(repo) |> Path.split() |> Enum.take(-4) == ["foo", "bar", "meta", "retros"]
      assert RepoBase.analytics_path(repo) |> Path.split() |> Enum.take(-3) == ["foo", "bar", "analytics"]
      assert RepoBase.repo_relative_path(repo) == ".aiur/repo/foo/bar"
    end

    test "rejects repo identities that would escape the state root", %{tmp: tmp} do
      previous_root = Application.get_env(:aiur, :repo_base_root)
      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "state"))

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      # `..` landing in the final two slug segments would resolve outside the
      # state root; the CLI already rejects these, this guards the lib boundary.
      for malicious <- [
            "https://github.com/../escape",
            "https://github.com/owner/..",
            "owner/../project",
            "owner/project/.."
          ] do
        assert_raise ArgumentError, fn -> RepoBase.repo_path(malicious) end
        assert_raise ArgumentError, fn -> RepoBase.repo_relative_path(malicious) end
      end
    end
  end

  describe "setup_state/2" do
    test "creates the complete state tree and imports a legacy retrospective", %{tmp: tmp} do
      previous_root = Application.get_env(:aiur, :repo_base_root)
      state_root = Path.join(tmp, "state")
      source_root = Path.join(tmp, "source")
      File.mkdir_p!(Path.join([source_root, "docs", "executor"]))
      File.write!(Path.join([source_root, "docs", "executor", "hourly-retrospectives.md"]), "legacy notes\n")
      Application.put_env(:aiur, :repo_base_root, state_root)

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      repo = "https://github.com/foo/bar.git"
      assert :ok = RepoBase.setup_state(repo, source_root)
      assert :ok = RepoBase.setup_state(repo, source_root)

      assert File.dir?(RepoBase.base_path(repo))
      assert File.dir?(RepoBase.builds_path(repo))
      assert File.dir?(RepoBase.analytics_path(repo))
      assert File.dir?(RepoBase.retros_path(repo))
      assert File.regular?(RepoBase.findings_path(repo))

      for sidecar <- [".aiur-hex", ".aiur-mix", ".aiur-npm-cache"] do
        assert File.dir?(Path.join(RepoBase.repo_path(repo), sidecar))
      end

      assert [imported] = Path.wildcard(Path.join(RepoBase.retros_path(repo), "legacy-*.md"))
      assert File.read!(imported) == "legacy notes\n"
    end

    test "refuses a state-tree symlink before creating a findings ledger", %{tmp: tmp} do
      previous_root = Application.get_env(:aiur, :repo_base_root)
      repo = "https://github.com/foo/bar.git"
      node = Path.join([tmp, "state", "foo", "bar"])
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(node)
      File.mkdir_p!(outside)
      assert :ok = File.ln_s(outside, Path.join(node, "meta"))
      Application.put_env(:aiur, :repo_base_root, Path.join(tmp, "state"))

      on_exit(fn ->
        case previous_root do
          nil -> Application.delete_env(:aiur, :repo_base_root)
          root -> Application.put_env(:aiur, :repo_base_root, root)
        end
      end)

      assert {:error, {:repo_base_state_path_symlink, _}} = RepoBase.ensure_state_tree(repo)
      refute File.exists?(Path.join(outside, "findings.ndjson"))
    end
  end

  describe "base_branch/0" do
    # Pins the workflow config per test (same pattern as the "server state
    # machine" setup below) so resolution never depends on ambient config.
    setup do
      tmp = Path.join(System.tmp_dir!(), "rb_bb_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      cfg = Path.join(tmp, "config")
      prev_path = Application.get_env(:aiur, :workflow_file_path)

      on_exit(fn ->
        case prev_path do
          nil -> Aiur.Workflow.clear_workflow_file_path()
          p -> Aiur.Workflow.set_workflow_file_path(p)
        end

        File.rm_rf!(tmp)
      end)

      {:ok, cfg: cfg}
    end

    test "defaults to main when tracker.base_branch is unset", %{cfg: cfg} do
      File.write!(cfg, "tracker:\n  kind: memory\n")
      Aiur.Workflow.set_workflow_file_path(cfg)

      assert RepoBase.base_branch() == "main"
    end

    test "returns the configured tracker.base_branch", %{cfg: cfg} do
      File.write!(cfg, "tracker:\n  kind: memory\n  base_branch: v2\n")
      Aiur.Workflow.set_workflow_file_path(cfg)

      assert RepoBase.base_branch() == "v2"
    end

    test "falls back to main when tracker.base_branch is empty", %{cfg: cfg} do
      File.write!(cfg, ~s(tracker:\n  kind: memory\n  base_branch: ""\n))
      Aiur.Workflow.set_workflow_file_path(cfg)

      assert RepoBase.base_branch() == "main"
    end
  end

  describe "status/0" do
    test "returns a {phase, base_path} tuple" do
      assert {_phase, _base} = RepoBase.status()
    end
  end

  describe "server state machine" do
    setup do
      # Pin a prewarm-disabled config and force the shared WorkflowStore cache to
      # reload it, so `resolve/0` is deterministically `:disabled` and the instance
      # never schedules a poll. Otherwise a sibling test that left a prewarm-enabled
      # config cached makes the auto-poll start a real build mid-test (flaky).
      tmp = Path.join(System.tmp_dir!(), "rb_cfg_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      cfg = Path.join(tmp, "config")
      File.write!(cfg, "tracker:\n  kind: memory\n")
      prev_path = Application.get_env(:aiur, :workflow_file_path)
      Aiur.Workflow.set_workflow_file_path(cfg)

      # An unnamed instance so we can drive its handlers without colliding with
      # the supervised singleton (which always registers __MODULE__).
      {:ok, pid} = GenServer.start_link(RepoBase, [])

      on_exit(fn ->
        Aiur.TestSupport.safe_stop(pid)

        case prev_path do
          nil -> Aiur.Workflow.clear_workflow_file_path()
          p -> Aiur.Workflow.set_workflow_file_path(p)
        end

        File.rm_rf!(tmp)
      end)

      {:ok, server: pid}
    end

    test "starts idle", %{server: pid} do
      assert %{phase: :idle, build: nil, probe: nil} = :sys.get_state(pid)
    end

    test "refresh_async is a no-op when pre-warm is disabled", %{server: pid} do
      GenServer.cast(pid, :refresh_async)
      assert %{phase: :idle} = :sys.get_state(pid)
    end

    test "build_done success marks ready and records the head", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: %{pid: pid, ref: make_ref(), head: "abc"}, phase: :building}
      end)

      send(pid, {:build_done, pid, "abc", {:ok, "/base"}})

      assert %{phase: :ready, base_path: "/base", ready_head: "abc", freshness: :unknown, build: nil} =
               :sys.get_state(pid)
    end

    test "build_done error sets the error phase", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: %{pid: pid, ref: make_ref(), head: nil}, phase: :building}
      end)

      send(pid, {:build_done, pid, nil, {:error, :boom}})

      assert %{phase: {:error, :boom}, build: nil} = :sys.get_state(pid)
    end

    test "build_head records the locked head on the in-flight build", %{server: pid} do
      :sys.replace_state(pid, fn s -> %{s | build: %{pid: pid, ref: make_ref(), head: nil}} end)

      send(pid, {:build_head, pid, "deadbeef"})

      assert %{build: %{head: "deadbeef"}} = :sys.get_state(pid)
    end

    test "a crashed build process surfaces an error phase", %{server: pid} do
      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | build: %{pid: self(), ref: ref, head: nil}, phase: :building} end)

      send(pid, {:DOWN, ref, :process, self(), :killed})

      assert %{phase: {:error, {:build_crashed, :killed}}, build: nil} = :sys.get_state(pid)
    end

    test "a remote-head advance past a ready base triggers a rebuild", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: nil, phase: :ready, ready_head: "old", probe: probe(pid)}
      end)

      send(pid, {:remote_head, pid, {:ok, "new"}})

      # resolve is disabled in test, so the triggered rebuild resolves to idle.
      assert %{phase: :idle, probe: nil} = :sys.get_state(pid)
    end

    test "a remote-head with no advance leaves a ready base untouched", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: nil, phase: :ready, ready_head: "same", probe: probe(pid)}
      end)

      send(pid, {:remote_head, pid, {:ok, "same"}})

      assert %{phase: :ready} = :sys.get_state(pid)
    end

    test "a matching dispatch freshness check marks the ready base fresh", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: nil, phase: :checking, ready_head: "same", freshness: :unknown, probe: probe(pid)}
      end)

      send(pid, {:remote_head, pid, {:ok, "same"}})

      assert %{phase: :ready, freshness: :fresh} = :sys.get_state(pid)
    end

    test "a failed freshness check never certifies the warm base", %{server: pid} do
      :sys.replace_state(pid, fn s ->
        %{s | build: nil, phase: :checking, ready_head: "same", freshness: :unknown, probe: probe(pid)}
      end)

      send(pid, {:remote_head, pid, {:error, :timeout}})

      assert %{phase: {:error, {:repo_base_remote_probe_failed, :timeout}}, freshness: :unknown} =
               :sys.get_state(pid)
    end
  end

  defp probe(pid), do: %{pid: pid, ref: make_ref(), timer: nil}

  describe "git_auth_env/1" do
    test "injects the token as a per-host Authorization header via env config" do
      env = RepoBase.git_auth_env("ghp_secrettoken")
      assert {"GIT_CONFIG_COUNT", "1"} in env
      assert {"GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader"} in env
      assert {"GIT_TERMINAL_PROMPT", "0"} in env

      {_k, value} = Enum.find(env, fn {k, _v} -> k == "GIT_CONFIG_VALUE_0" end)
      assert "AUTHORIZATION: basic " <> b64 = value
      assert Base.decode64!(b64) == "x-access-token:ghp_secrettoken"
    end

    test "carries the secret only in the env (base64-encoded), never in plaintext" do
      # The token rides in `env:` to System.cmd, never on argv, and even there it
      # only appears base64-encoded inside the Authorization header — so a raw
      # token string never lands in argv/`ps` or the env list verbatim.
      env = RepoBase.git_auth_env("ghp_secrettoken")
      refute inspect(env) =~ "ghp_secrettoken"

      {_k, value} = Enum.find(env, fn {k, _v} -> k == "GIT_CONFIG_VALUE_0" end)
      assert "AUTHORIZATION: basic " <> b64 = value
      assert Base.decode64!(b64) =~ "ghp_secrettoken"
    end

    test "with no token, disables the terminal prompt and injects no credential" do
      for token <- [nil, ""] do
        env = RepoBase.git_auth_env(token)
        assert env == [{"GIT_TERMINAL_PROMPT", "0"}]
        refute Enum.any?(env, fn {k, _v} -> String.starts_with?(k, "GIT_CONFIG") end)
      end
    end
  end

  defp git!(args) do
    {out, status} = System.cmd("git", args, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end

  defp head(repo) do
    {out, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"], stderr_to_stdout: true)
    String.trim(out)
  end
end
