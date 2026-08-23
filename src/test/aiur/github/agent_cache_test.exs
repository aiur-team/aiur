defmodule Aiur.GitHub.AgentCacheTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Aiur.GitHub.AgentCache

  setup %{tmp_dir: root} do
    {:ok, opts: [state_dir: root], root: Path.join(root, "state-cache/v1")}
  end

  test "the root matches the path the gh wrapper derives", %{opts: opts, root: root} do
    # The wrapper computes `$AIUR_GITHUB_BUDGET_ROOT/state-cache/v1`. If these
    # two ever drift the daemon marks resources no agent is reading, and the
    # cache silently stops honouring free webhook writes.
    assert AgentCache.root(opts) == root
  end

  test "invalidating a resource marks both number spaces and the collections", %{opts: opts, root: root} do
    assert :ok = AgentCache.invalidate("aiur-team/aiur", 2073, opts)

    assert File.exists?(Path.join(root, "aiur-team/aiur/pr/2073/.invalidated"))
    assert File.exists?(Path.join(root, "aiur-team/aiur/issue/2073/.invalidated"))
    assert File.exists?(Path.join(root, "aiur-team/aiur/.collections-invalidated"))
  end

  test "a marker holds a unix second an entry can be compared against", %{opts: opts, root: root} do
    before = System.system_time(:second)
    assert :ok = AgentCache.invalidate("aiur-team/aiur", "2073", opts)

    marked =
      Path.join(root, "aiur-team/aiur/pr/2073/.invalidated")
      |> File.read!()
      |> String.trim()
      |> String.to_integer()

    assert marked >= before
    assert marked <= System.system_time(:second)
  end

  test "collection invalidation leaves individual resources alone", %{opts: opts, root: root} do
    assert :ok = AgentCache.invalidate_collections("aiur-team/aiur", opts)

    assert File.exists?(Path.join(root, "aiur-team/aiur/.collections-invalidated"))
    refute File.exists?(Path.join(root, "aiur-team/aiur/pr"))
  end

  test "repository invalidation retires every read of the repo", %{opts: opts, root: root} do
    assert :ok = AgentCache.invalidate_repo("aiur-team/aiur", opts)

    assert File.exists?(Path.join(root, "aiur-team/aiur/.invalidated"))
  end

  # Owner and repo segments arrive from webhook payloads, so they are
  # attacker-influenced input to a filesystem write.
  test "a traversal or malformed identity writes nothing", %{opts: opts, root: root} do
    assert :ok = AgentCache.invalidate("../..", 1, opts)
    assert :ok = AgentCache.invalidate("aiur-team/../../escape", 1, opts)
    assert :ok = AgentCache.invalidate("aiur-team/", 1, opts)
    assert :ok = AgentCache.invalidate("aiur", 1, opts)
    assert :ok = AgentCache.invalidate_repo("a/b/c", opts)

    refute File.exists?(root)
  end

  test "a number that is not a positive integer writes nothing", %{opts: opts, root: root} do
    assert :ok = AgentCache.invalidate("aiur-team/aiur", "not-a-number", opts)
    assert :ok = AgentCache.invalidate("aiur-team/aiur", 0, opts)
    assert :ok = AgentCache.invalidate("aiur-team/aiur", "12abc", opts)

    refute File.exists?(Path.join(root, "aiur-team/aiur/pr"))
  end

  test "an unwritable store never fails the caller", %{opts: opts} do
    blocked = Path.join(Keyword.fetch!(opts, :state_dir), "blocked")
    File.write!(blocked, "not a directory")

    assert :ok = AgentCache.invalidate("aiur-team/aiur", 2073, state_dir: blocked)
    assert :ok = AgentCache.invalidate_repo("aiur-team/aiur", state_dir: blocked)
  end

  describe "read_body/2 — the daemon's read half of the two-store sync" do
    alias Aiur.GitHub.ResourceStore

    setup %{opts: opts} do
      AgentCache.reset_daemon_served_reads()
      {:ok, opts: opts}
    end

    # A raw `gh api repos/owner/repo/issues/1670` read: the wrapper's stdout is
    # the full REST issue object, which is exactly what `read_body/2` validates.
    defp issue_json(number, opts \\ []) do
      %{
        "number" => number,
        "url" => Keyword.get(opts, :url) || "https://api.github.com/repos/owner/repo/issues/#{number}",
        "state" => Keyword.get(opts, :state, "open"),
        "title" => "issue #{number}"
      }
      |> Jason.encode!()
    end

    defp write_entry(root, kind, id, shape, body, fetched_at_s \\ System.os_time(:second)) do
      dir = Path.join([root, "owner", "repo", kind, to_string(id)])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "#{shape}.body"), body)
      File.write!(Path.join(dir, "#{shape}.meta"), "#{fetched_at_s}\n")
      dir
    end

    defp key(type, id) do
      ResourceStore.key(type, "owner", "repo", to_string(id))
    end

    test "serves a fresh raw gh api issue body that validates", %{opts: opts, root: root} do
      write_entry(root, "issue", 1670, "shape-a", issue_json(1670))

      assert {:ok, %{"number" => 1670, "state" => "open"}} = AgentCache.read_body(key(:issue, 1670), opts)
    end

    test "a projected gh --json shape is never mistaken for the resource", %{opts: opts, root: root} do
      # `gh issue view 1670 --json body -q .body` stores {"body": "..."} — no
      # number, no API url — under the same issue directory.
      write_entry(root, "issue", 1670, "projection", ~s({"body": "hello"}))

      assert AgentCache.read_body(key(:issue, 1670), opts) == :miss
    end

    test "a projected shape is skipped in favour of a valid shape behind it", %{opts: opts, root: root} do
      now = System.os_time(:second)
      # The freshest shape is a projection; the older one is a valid raw read.
      write_entry(root, "issue", 1670, "freshest-projection", ~s({"body": "hello"}), now)
      write_entry(root, "issue", 1670, "older-raw", issue_json(1670), now - 10)

      assert {:ok, %{"number" => 1670}} = AgentCache.read_body(key(:issue, 1670), opts)
    end

    test "a body for a different number is rejected", %{opts: opts, root: root} do
      write_entry(root, "issue", 1670, "shape-a", issue_json(9999))

      assert AgentCache.read_body(key(:issue, 1670), opts) == :miss
    end

    test "an entry stamped in the future is a miss", %{opts: opts, root: root} do
      write_entry(root, "issue", 1670, "shape-a", issue_json(1670), System.os_time(:second) + 60)

      assert AgentCache.read_body(key(:issue, 1670), opts) == :miss
    end

    test "an entry older than the backstop window is a miss", %{opts: opts, root: root} do
      write_entry(root, "issue", 1670, "shape-a", issue_json(1670), System.os_time(:second) - 120)

      assert AgentCache.read_body(key(:issue, 1670), opts) == :miss
    end

    test "the caller's tighter freshness tolerance wins over the backstop", %{opts: opts, root: root} do
      write_entry(root, "issue", 1670, "shape-a", issue_json(1670), System.os_time(:second) - 5)

      # 5 seconds old: fine within the caller's 10-second tolerance...
      assert {:ok, _body} = AgentCache.read_body(key(:issue, 1670), opts ++ [freshness_ms: 10_000])

      # ...and a miss within a 1-second tolerance.
      assert AgentCache.read_body(key(:issue, 1670), opts ++ [freshness_ms: 1_000]) == :miss
    end

    test "an entry marker newer than the fetch retires the entry", %{opts: opts, root: root} do
      now = System.os_time(:second)
      write_entry(root, "issue", 1670, "shape-a", issue_json(1670), now - 5)
      dir = Path.join([root, "owner", "repo", "issue", "1670"])

      File.write!(Path.join(dir, ".invalidated"), "#{now}\n")
      assert AgentCache.read_body(key(:issue, 1670), opts) == :miss

      File.write!(Path.join(dir, ".invalidated"), "#{now - 20}\n")
      assert {:ok, _body} = AgentCache.read_body(key(:issue, 1670), opts)
    end

    test "a repository or root marker newer than the fetch retires the entry", %{opts: opts, root: root} do
      now = System.os_time(:second)
      write_entry(root, "issue", 1670, "shape-a", issue_json(1670), now - 5)

      File.write!(Path.join([root, "owner", "repo", ".invalidated"]), "#{now}\n")
      assert AgentCache.read_body(key(:issue, 1670), opts) == :miss

      File.rm(Path.join([root, "owner", "repo", ".invalidated"]))
      File.write!(Path.join(root, ".invalidated"), "#{now}\n")
      assert AgentCache.read_body(key(:issue, 1670), opts) == :miss
    end

    test "a non-JSON or torn entry is a miss, never a raise", %{opts: opts, root: root} do
      write_entry(root, "issue", 1670, "garbage", "not json at all")
      assert AgentCache.read_body(key(:issue, 1670), opts) == :miss

      dir = write_entry(root, "issue", 1670, "torn", issue_json(1670))
      File.rm!(Path.join(dir, "torn.body"))
      assert AgentCache.read_body(key(:issue, 1670), opts) == :miss

      File.rm(Path.join(dir, "torn.meta"))
      write_entry(root, "issue", 1670, "missing-meta", issue_json(1670))
      File.rm!(Path.join(dir, "missing-meta.meta"))
      assert AgentCache.read_body(key(:issue, 1670), opts) == :miss
    end

    test "a missing or absent store answers :miss and never raises", %{opts: opts} do
      assert AgentCache.read_body(key(:issue, 1670), state_dir: Path.join(Keyword.fetch!(opts, :state_dir), "nowhere")) == :miss
      assert AgentCache.read_body(nil, opts) == :miss
    end

    test "a resource type outside the readable set answers :miss", %{opts: opts, root: root} do
      write_entry(root, "issue", 1670, "shape-a", issue_json(1670))

      # `:issue_labels` files under the same issue directory but expects a
      # different projection, so it is deliberately not served.
      assert AgentCache.read_body(key(:issue_labels, 1670), opts) == :miss
      # A collection key has no agent directory at all.
      assert AgentCache.read_body(key(:branch_pull_request_listing, 1670), opts) == :miss
    end

    test "record_served_read/0 counts each serve for the measured reduction", %{opts: opts, root: root} do
      write_entry(root, "issue", 1670, "shape-a", issue_json(1670))

      assert AgentCache.daemon_served_reads() == 0
      assert {:ok, _body} = AgentCache.read_body(key(:issue, 1670), opts)
      assert AgentCache.daemon_served_reads() == 0

      AgentCache.record_served_read()
      assert AgentCache.daemon_served_reads() == 1

      AgentCache.reset_daemon_served_reads()
      assert AgentCache.daemon_served_reads() == 0
    end
  end
end
