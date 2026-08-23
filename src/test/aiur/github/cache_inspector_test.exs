defmodule Aiur.GitHub.CacheInspectorTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.CacheInspector
  alias Aiur.GitHub.CacheInspector.{Entry, Redactor, ResourceStoreSource}
  alias Aiur.GitHub.ResourceStore

  @now ~U[2026-08-17 12:00:00Z]
  @thresholds %{stale_after_ms: 5 * 60 * 1000, expired_after_ms: 72 * 60 * 60 * 1000}

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
        entry(:pull_request, "9", :fetch, 5)
      ]
    end

    defp entry(type, id, source, age_seconds) do
      recorded = DateTime.to_unix(DateTime.add(~U[2026-08-17 12:00:00Z], -age_seconds, :second), :millisecond)

      %{
        key: {type, "owner", "repo", id},
        etag: "etag-#{id}",
        version: "v#{id}",
        data_version: "v#{id}",
        source: source,
        fetched_at_ms: recorded,
        recorded_at_ms: recorded,
        data?: true,
        data: %{"id" => id}
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
      assert comments.freshness == %{fresh: 1, stale: 1, expired: 1, unknown: 0}
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

      assert writers == [:fetch, :mutation, :poll, :webhook]
    end

    test "accepts the design's writer vocabulary as well as the store's" do
      # The design names the writers mutation write-through, webhook,
      # need-driven fetch and safety sweep; the store's own option vocabulary is
      # `:mutation`, `:webhook`, `:fetch`, `:poll`. Both must land in the same
      # bucket, because an operator filtering by writer should not have to know
      # which unit wrote which word.
      assert writer_for(:need) == :fetch
      assert writer_for(:sweep) == :poll
      assert writer_for(:write_through) == :mutation
      assert writer_for(:delivery) == :webhook

      # An unrecognised source is named as unrecognised rather than coerced onto
      # a writer that did not make the write.
      assert writer_for(:something_new) == :other
      assert writer_for(nil) == :other
    end

    test "reports the row cap per resource type, not as one global slice" do
      projection = CacheInspector.project(source: FixedSource, now: @now, limit: 2)

      # The cap is a rendering budget per group, so every group keeps rows. A
      # single global `Enum.take` over a list ordered by type name gave the
      # alphabetically-late type zero rows while its map tile still advertised
      # a full count — and its group page then claimed nothing matched.
      assert [comments, pulls] = projection.groups
      assert comments.resource_type == :issue_comment
      assert comments.count == 3 and comments.shown == 2 and comments.elided == 1
      assert pulls.count == 1 and pulls.shown == 1 and pulls.elided == 0

      # Nothing was dropped from the projection itself at this size.
      assert projection.total == 4
      assert projection.projected == 4
      assert projection.elided == 0
      assert projection.limit == 2
    end

    test "states how many entries it did not classify at all" do
      projection = CacheInspector.project(source: FixedSource, now: @now, ceiling: 2)

      assert projection.total == 4
      assert projection.projected == 2
      assert projection.elided == 2
      assert projection.ceiling == 2
    end

    test "truncation keeps the states that need attention" do
      projection = CacheInspector.project(source: FixedSource, now: @now, ceiling: 2)

      # Stalest first within a type, so what survives is what an operator would
      # have opened the page to find rather than whatever sorted first.
      assert Enum.any?(projection.entries, &(&1.freshness == :expired))
    end

    test "a bodyless entry outranks an aged one for the last remaining slot" do
      defmodule MixedSource do
        @behaviour Aiur.GitHub.CacheInspector.Source
        @impl true
        def available?, do: true

        @impl true
        def entries do
          [
            %{key: {:issue, "o", "r", "old"}, source: :poll, data?: true, data: %{}, fetched_at_ms: 1},
            %{key: {:issue, "o", "r", "none"}, source: :poll, etag: "W/\"x\"", data?: false}
          ]
        end
      end

      # An earlier sort used `-(age_ms || 0)`, which sent every entry with no
      # recorded fetch time to the end of its type — so the bodyless entry, the
      # exact state this page exists to surface, was elided first.
      projection = CacheInspector.project(source: MixedSource, now: @now, ceiling: 1)

      assert [%{id: "none", bodyless?: true}] = projection.entries
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

  describe "history_sample/1" do
    test "classifies every entry the source holds, with counts that sum" do
      sample = CacheInspector.history_sample(@now, source: FixedSource)

      # 30s → fresh, 600s → stale (past the 5-minute window), 300,000,000s →
      # expired, 5s → fresh. Every one holds a body.
      assert sample.total == 4
      assert sample.with_body == 4
      assert sample.bodyless == 0
      assert sample.fresh == 2
      assert sample.stale == 1
      assert sample.expired == 1
      assert sample.unknown == 0
      assert sample.t_ms == DateTime.to_unix(@now, :millisecond)
    end

    test "keeps validator-only entries apart from the bodies" do
      # `BodylessSource` is scoped to the describe block that defines it, so it
      # is referenced by its full name from here.
      sample = CacheInspector.history_sample(@now, source: Aiur.GitHub.CacheInspectorTest.BodylessSource)

      # One validator-only entry (freshness unknown — a bodyless entry has no
      # freshness) and one held body recorded in 1970 (expired).
      assert sample.total == 2
      assert sample.with_body == 1
      assert sample.bodyless == 1
      assert sample.expired == 1
      assert sample.unknown == 1
      assert sample.fresh == 0 and sample.stale == 0
    end

    test "an unavailable store answers nil rather than a fabricated zero" do
      # The chart must not draw a flat zero over a span the sampler never
      # observed, any more than the page renders "0 entries" over a missing
      # store. `nil` is how the sampler records nothing.
      assert CacheInspector.history_sample(@now, source: EmptySource) == nil
    end

    test "a corrupt store degrades to nil rather than taking the sampler down" do
      assert CacheInspector.history_sample(@now, source: ExplodingSource) == nil
    end

    test "the real store answers a sample that matches its projection totals" do
      key = ResourceStore.key(:issue_comment, "owner", "repo", 525_000)
      :ok = ResourceStore.put_resource(key, %{"body" => "sampled"}, source: :webhook, version: "v1", etag: "W/\"s\"")

      projection = CacheInspector.project(source: ResourceStoreSource, limit: 100_000)
      sample = CacheInspector.history_sample(@now, source: ResourceStoreSource)

      assert sample.total == projection.total
      assert sample.bodyless == projection.bodyless
      assert sample.with_body == projection.with_body
    end
  end

  describe "a validator with no body" do
    defmodule BodylessSource do
      @behaviour Aiur.GitHub.CacheInspector.Source
      @impl true
      def available?, do: true

      @impl true
      def entries do
        [
          %{
            key: {:issue_comment, "o", "r", "1"},
            etag: "W/\"kept\"",
            source: :poll,
            data?: false,
            recorded_at_ms: 1
          },
          %{
            key: {:issue_comment, "o", "r", "2"},
            etag: "W/\"held\"",
            source: :webhook,
            data?: true,
            data: %{"id" => "2"},
            fetched_at_ms: 1,
            recorded_at_ms: 1
          }
        ]
      end
    end

    test "is distinguished from a cache hit rather than counted as one" do
      projection = CacheInspector.project(source: BodylessSource, now: @now)

      assert projection.total == 2
      assert projection.bodyless == 1
      assert projection.with_body == 1

      bodyless = CacheInspector.find(projection, "issue_comment:o:r:1")

      # The validator is genuinely held — dropping the body deliberately leaves
      # it — so an inspector that reported "nothing cached" would be wrong too.
      assert bodyless.validator?
      refute bodyless.body?
      assert bodyless.bodyless?

      held = CacheInspector.find(projection, "issue_comment:o:r:2")
      assert held.validator?
      assert held.body?
      refute held.bodyless?
    end

    test "is counted per group, so a whole region of them is visible on the map" do
      projection = CacheInspector.project(source: BodylessSource, now: @now)

      assert [%{resource_type: :issue_comment, bodyless: 1}] = projection.groups
    end

    test "renders no payload, because there is none to render" do
      projection = CacheInspector.project(source: BodylessSource, now: @now)

      assert projection |> CacheInspector.find("issue_comment:o:r:1") |> Entry.payload() == nil

      # And the entry that does hold one still renders it, redacted.
      assert projection |> CacheInspector.find("issue_comment:o:r:2") |> Entry.payload() == %{"id" => "2"}
    end

    test "a body that is falsy is still a body" do
      # `false`, `0` and `[]` are legitimate cached bodies. Deciding on
      # truthiness rather than presence would mark them bodyless and send a
      # reader off to pay for something the store already holds.
      for body <- [false, 0, [], ""] do
        entry = Entry.new(%{key: {:issue, "o", "r", "1"}, data?: true, data: body}, @now, @thresholds)

        assert entry.body?, "a cached #{inspect(body)} was reported as no body at all"
        refute entry.bodyless?
      end
    end
  end

  describe "reading the real store" do
    test "a deposit and a drop_data are both visible for what they are" do
      held = ResourceStore.key(:issue_comment, "owner", "repo", 4242)
      dropped = ResourceStore.key(:issue_comment, "owner", "repo", 4243)

      :ok = ResourceStore.put_resource(held, %{"body" => "kept"}, source: :webhook, version: "v1", etag: "W/\"a\"")
      :ok = ResourceStore.put_resource(dropped, %{"body" => "gone"}, source: :poll, version: "v2", etag: "W/\"b\"")
      :ok = ResourceStore.drop_data(dropped)

      # The store is global and other cases in this suite write to it, so the
      # limit is raised rather than left at the page's default: a truncated
      # projection would fail this for a reason that has nothing to do with what
      # it is asserting.
      projection = CacheInspector.project(source: ResourceStoreSource, limit: 100_000)

      held_entry = CacheInspector.find(projection, "issue_comment:owner:repo:4242")
      dropped_entry = CacheInspector.find(projection, "issue_comment:owner:repo:4243")

      assert held_entry.body?
      assert held_entry.writer == :webhook
      assert held_entry.data_version == "v1"
      assert held_entry.etag == "W/\"a\""

      # `drop_data/1` keeps the validator on purpose. That is exactly the state
      # a reader must not mistake for a hit, so the projection names it.
      assert dropped_entry.bodyless?
      refute dropped_entry.body?
      assert dropped_entry.validator? and dropped_entry.etag == "W/\"b\""
    end

    test "a dropped body reads as unknown freshness, not as fresh" do
      # `drop_data/1` keeps `fetched_at_ms` along with the validator, so a
      # bodyless entry still carries a real age. Every hand-built fixture in
      # this suite fakes `fetched_at_ms: nil`, which is not what the store
      # produces — so this goes through the real call. Labelling that entry
      # `:fresh` would put the most misleading word available next to the state
      # the page exists to warn about.
      key = ResourceStore.key(:issue_comment, "owner", "repo", 4244)
      :ok = ResourceStore.put_resource(key, %{"body" => "here"}, source: :poll, version: "v1", etag: "W/\"c\"")
      :ok = ResourceStore.drop_data(key)

      entry =
        CacheInspector.project(source: ResourceStoreSource, limit: 100_000)
        |> CacheInspector.find("issue_comment:owner:repo:4244")

      assert entry.bodyless?
      assert entry.freshness == :unknown
      # The age survives, because it is still a true fact about the body that
      # was dropped — it is just not a claim about what the store can serve.
      assert is_integer(entry.age_ms)
    end
  end

  describe "find/2" do
    test "resolves a deep-linked identity and answers nil for a miss" do
      projection = CacheInspector.project(source: FixedSource, now: @now)

      assert %{id: "2"} = CacheInspector.find(projection, "issue_comment:owner:repo:2")
      assert CacheInspector.find(projection, "issue_comment:owner:repo:404") == nil
    end
  end

  describe "view_fetches/1" do
    test "counts only requests attributed to a LiveView process" do
      snapshot = %{
        callers: [
          %{caller: "comment_poll_batch", calls: 40, view_calls: 0},
          %{caller: "issue_relationships", calls: 3, view_calls: 3}
        ]
      }

      assert CacheInspector.view_fetches(snapshot) == 3
    end

    test "does not infer request origin from caller-name substrings" do
      snapshot = %{
        callers: [
          %{caller: :review_threads_unaddressed, calls: 20, view_calls: 0},
          %{caller: :paginated_issue_poll, calls: 100, view_calls: 0},
          %{caller: :dashboard_live, calls: 7, view_calls: 0}
        ]
      }

      assert CacheInspector.view_fetches(snapshot) == 0
    end

    test "reads zero when nothing views and fetches, which is the steady state" do
      assert CacheInspector.view_fetches(%{callers: [%{caller: "bot_identity", calls: 9}]}) == 0
      assert CacheInspector.view_fetches(%{}) == 0
    end

    test "reports the total the meter attributed, so a zero can be read honestly" do
      # Zero view fetches against a meter that saw 49 calls says the view paths
      # spent nothing. Zero against a meter that saw nothing says only that
      # nobody has measured yet, and the page prints both figures for that reason.
      snapshot = %{callers: [%{caller: "comment_poll_batch", calls: 40}, %{caller: "bot_identity", calls: 9}]}

      assert CacheInspector.observed_calls(snapshot) == 49
      assert CacheInspector.observed_calls(%{}) == 0
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

      assert deep |> Redactor.redact() |> inspect() =~ "elided: nesting depth"

      long = Enum.map(1..500, &%{"i" => &1})
      assert List.last(Redactor.redact(long)) =~ "elided: 300 more items"
    end

    test "scrubs the ETag and both version fields, not only the payload" do
      token = "ghs_" <> String.duplicate("D", 36)

      entry =
        Entry.new(
          %{
            key: {:issue_comment, "o", "r", "1"},
            etag: token,
            version: token,
            data_version: token,
            source: :webhook
          },
          @now,
          %{stale_after_ms: 1, expired_after_ms: 2}
        )

      refute entry.etag =~ token
      refute entry.version =~ token
      refute entry.data_version =~ token
    end
  end

  describe "the default source" do
    test "is used even when nothing has loaded its module yet" do
      # `function_exported?/3` answers false for a module that is only not
      # loaded yet. Deciding availability on it alone made the page render "no
      # cache store is running" over a store that was running and full — the
      # worst failure this page has, because it looks like a working page
      # reporting bad news rather than a broken one.
      :code.purge(ResourceStoreSource)
      :code.delete(ResourceStoreSource)

      key = ResourceStore.key(:issue, "owner", "repo", 8888)
      :ok = ResourceStore.put_resource(key, %{"number" => 8888}, source: :webhook, version: "v1")

      assert CacheInspector.project(source: ResourceStoreSource, limit: 100_000).available?
    end

    test "reads the store's own record shape, field for field" do
      key = ResourceStore.key(:pull_request, "owner", "repo", 7777)
      :ok = ResourceStore.put_resource(key, %{"number" => 7777}, source: :mutation, version: "v9", etag: "W/\"z\"")

      assert ResourceStoreSource.available?()

      row = Enum.find(ResourceStoreSource.entries(), &(&1.key == key))

      # Named explicitly, because the previous version of this source read
      # `:payload` and `:fetched_at` — fields the store has never had — and
      # therefore rendered every entry as bodyless and undated while looking
      # like it worked.
      assert row.data == %{"number" => 7777}
      assert row.data?
      assert row.data_version == "v9"
      assert row.etag == "W/\"z\""
      assert row.source == :mutation
      assert is_integer(row.fetched_at_ms)
      assert is_integer(row.recorded_at_ms)
    end
  end

  defp writer_for(source) do
    %{key: {:issue, "o", "r", "1"}, source: source}
    |> Entry.new(@now, @thresholds)
    |> Map.fetch!(:writer)
  end
end
