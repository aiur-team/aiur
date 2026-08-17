defmodule Aiur.GitHub.CacheInspectorTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.CacheInspector
  alias Aiur.GitHub.CacheInspector.{Entry, Redactor, ResourceStoreSource}

  @now ~U[2026-08-17 12:00:00Z]

  defmodule EmptySource do
    @behaviour Aiur.GitHub.CacheInspector.Source
    @impl true
    def available?, do: false
    @impl true
    def entries, do: []
  end

  defmodule ExplodingSource do
    @behaviour Aiur.GitHub.CacheInspector.Source
    @impl true
    def available?, do: true
    @impl true
    def entries, do: raise("corrupt store")
  end

  defmodule FixedSource do
    @behaviour Aiur.GitHub.CacheInspector.Source
    @impl true
    def available?, do: true

    @impl true
    def entries do
      [
        entry(:issue_comment, "1", :webhook, 30),
        entry(:issue_comment, "2", :mutation, 600),
        entry(:issue_comment, "3", :poll, 300_000_000),
        entry(:pull_request, "9", :need, 5)
      ]
    end

    defp entry(type, id, source, age_seconds) do
      %{
        key: {type, "Owner", "Repo", id},
        etag: "etag-#{id}",
        version: "v#{id}",
        source: source,
        writes: 2,
        fetched_at: DateTime.add(~U[2026-08-17 12:00:00Z], -age_seconds, :second),
        payload: %{"id" => id}
      }
    end
  end

  describe "project/1" do
    test "groups by resource type and classifies freshness" do
      projection = CacheInspector.project(source: FixedSource, now: @now)

      assert projection.available?
      assert projection.total == 4

      [comments, pulls] = projection.groups

      assert comments.resource_type == :issue_comment
      assert comments.count == 3
      assert comments.freshness == %{fresh: 1, stale: 1, expired: 1}
      assert pulls.count == 1
    end

    test "a group is as stale as its worst entry, never as its average" do
      projection = CacheInspector.project(source: FixedSource, now: @now)
      [comments, _pulls] = projection.groups

      # Two of three are usable, and the tile still reads expired. A group
      # averaged to "mostly fresh" hides the one entry a decision is about to be
      # made on.
      assert comments.worst == :expired
      assert comments.stale_fraction > 0.0
    end

    test "maps store sources onto the four canonical writers" do
      projection = CacheInspector.project(source: FixedSource, now: @now)

      writers = projection.entries |> Enum.map(& &1.writer) |> Enum.sort()

      assert writers == [:mutation, :need, :sweep, :webhook]
    end

    test "downcases owner and repo consistently with the store's own key" do
      projection = CacheInspector.project(source: FixedSource, now: @now)

      assert Enum.any?(projection.entries, &(&1.identity == "pull_request:Owner:Repo:9"))
    end

    test "reports how many entries were elided rather than showing a subset" do
      projection = CacheInspector.project(source: FixedSource, now: @now, limit: 2)

      assert length(projection.entries) == 2
      assert projection.total == 4
      assert projection.elided == 2
      assert projection.limit == 2

      # Truncation keeps the stalest, so the region that needs attention is the
      # one that survives it.
      assert Enum.any?(projection.entries, &(&1.freshness == :expired))
    end

    test "an unavailable store is a state, not an error" do
      projection = CacheInspector.project(source: EmptySource, now: @now)

      refute projection.available?
      assert projection.entries == []
      assert projection.total == 0
    end

    test "a corrupt store degrades to unavailable rather than taking the page down" do
      projection = CacheInspector.project(source: ExplodingSource, now: @now)

      refute projection.available?
    end

    test "an entry with no fetch time is unknown, not expired" do
      defmodule UndatedSource do
        @behaviour Aiur.GitHub.CacheInspector.Source
        @impl true
        def available?, do: true
        @impl true
        def entries, do: [%{key: {:issue_comment, "o", "r", "1"}, source: :webhook}]
      end

      projection = CacheInspector.project(source: UndatedSource, now: @now)

      assert [%{freshness: :unknown, age_ms: nil}] = projection.entries
    end
  end

  describe "find/2" do
    test "resolves a deep-linked identity and answers nil for a miss" do
      projection = CacheInspector.project(source: FixedSource, now: @now)

      assert %{id: "2"} = CacheInspector.find(projection, "issue_comment:Owner:Repo:2")
      assert CacheInspector.find(projection, "issue_comment:Owner:Repo:404") == nil
    end
  end

  describe "view_fetches/1" do
    test "counts only call sites that declared themselves view paths" do
      snapshot = %{
        callers: [
          %{caller: "comment_poll_batch", calls: 40},
          %{caller: "view:some_future_page", calls: 3}
        ]
      }

      assert CacheInspector.view_fetches(snapshot) == 3
    end

    test "reads zero when nothing views and fetches, which is the steady state" do
      assert CacheInspector.view_fetches(%{callers: [%{caller: "bot_identity", calls: 9}]}) == 0
      assert CacheInspector.view_fetches(%{}) == 0
    end
  end

  describe "redaction" do
    test "drops a value whose key names a secret, whatever its shape" do
      redacted = Redactor.redact(%{"token" => "anything at all", "body" => "safe"})

      assert redacted["token"] == "[REDACTED:secret-key]"
      assert redacted["body"] == "safe"
    end

    test "redacts a token-shaped string even under an innocent key" do
      token = "ghp_" <> String.duplicate("B", 36)

      redacted = Redactor.redact(%{"body" => "my key is #{token}"})

      refute redacted["body"] =~ token
      assert redacted["body"] =~ "REDACTED"
    end

    test "reaches into nested maps and lists" do
      token = "github_pat_" <> String.duplicate("C", 30)

      redacted = Redactor.redact(%{"a" => [%{"b" => %{"authorization" => token, "note" => token}}]})

      [%{"b" => inner}] = redacted["a"]
      assert inner["authorization"] == "[REDACTED:secret-key]"
      refute inner["note"] =~ token
    end

    test "bounds depth and size so an inspector stays cheap to hold open" do
      deep = Enum.reduce(1..40, "leaf", fn _index, acc -> %{"next" => acc} end)

      assert Redactor.redact(deep) |> inspect() =~ "elided: nesting depth"

      long = Enum.map(1..500, &%{"i" => &1})
      assert List.last(Redactor.redact(long)) =~ "elided: 300 more items"
    end

    test "scrubs the ETag and version fields too, not only the payload" do
      token = "ghs_" <> String.duplicate("D", 36)

      entry =
        Entry.new(
          %{key: {:issue_comment, "o", "r", "1"}, etag: token, version: token, source: :webhook},
          @now,
          %{stale_after_ms: 1, expired_after_ms: 2}
        )

      refute entry.etag =~ token
      refute entry.version =~ token
    end
  end

  describe "the default source" do
    test "reports unavailable when no store table exists" do
      # This is the state on any branch where U1 has not landed, and it is the
      # same state a cold store produces, so it is not a special case.
      refute ResourceStoreSource.available?()
      assert ResourceStoreSource.entries() == []
    end
  end
end
