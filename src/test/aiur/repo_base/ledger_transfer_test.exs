defmodule Aiur.RepoBase.LedgerTransferTest do
  use Aiur.RepoBaseCase

  alias Aiur.Findings

  describe "refresh/3 ledger transfer" do
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
  end
end
