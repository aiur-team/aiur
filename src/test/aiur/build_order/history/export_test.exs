defmodule Aiur.BuildOrder.History.ExportTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.History.{Export, Row}
  alias Aiur.BuildOrder.{Lifecycle, ProviderHealth}

  @now ~U[2026-11-02 10:00:05Z]
  @observed ~U[2026-11-02 10:00:00Z]
  @general [%{key: "bugs", labels: ["bug"]}, %{key: "infra", labels: ["infra"]}]

  defp row(number, fields \\ []) do
    struct!(
      %Row{
        number: number,
        title: "Ticket #{number}",
        labels: [],
        labels_complete: true,
        pr_number: :none,
        lifecycle: %Lifecycle{state: :closed, state_reason: :completed},
        observed_at: @observed
      },
      fields
    )
  end

  defp healthy(opts \\ []), do: ProviderHealth.new(3, :healthy, Keyword.get(opts, :complete?, true), Keyword.merge([observed_at: @observed], opts))

  defp opts(rows, extra \\ []) do
    rows = Map.new(rows, &{&1.number, &1})
    overrides = Keyword.get(extra, :override_map, %{})
    owners = Keyword.get(extra, :owners, %{})

    Keyword.merge(
      [
        now: @now,
        history: fn -> {:ok, %{rows: rows, health: healthy(), repository: "o/r"}} end,
        overrides: fn -> {:ok, overrides, healthy()} end,
        features: fn -> {:ok, %{owners: owners, features: %{"pag" => %{epics: [%{key: "f-pag"}]}}, health: healthy()}} end,
        epics: fn -> {:ok, @general} end,
        issue_body: fn _number -> :miss end
      ],
      Keyword.drop(extra, [:override_map, :owners])
    )
  end

  defp numbers({:ok, page}), do: Enum.map(page.tickets, & &1.number)
  defp ticket({:ok, page}, number), do: Enum.find(page.tickets, &(&1.number == number))

  describe "--unsorted filter (V-1, V-2)" do
    setup do
      rows = [
        row(1, labels: ["question"]),
        row(2, labels: ["bug"]),
        row(3),
        row(4),
        row(5),
        row(6, labels: :unknown)
      ]

      override = %{epic: "infra", actor: "backfill-agent", confirmed: false}
      {:ok, opts: opts(rows, override_map: %{3 => override}, owners: %{4 => %{feature: "pag", epic: "f-pag"}})}
    end

    # The classifier resumes by re-reading with `unsorted: true`; a ticket it
    # already placed (override or feature) must drop out, and only a resolver
    # default counts as unsorted.
    test "keeps only default-unsorted tickets and counts them over all pages", %{opts: opts} do
      result = Export.page(Keyword.put(opts, :unsorted, true))

      assert numbers(result) == [1, 5]
      assert elem(result, 1).matching_total == 2
      assert ticket(result, 1).epic == %{key: "unsorted", source: "default"}
    end

    # A store gap must never make a ticket look unsorted, and must never vanish.
    test "an unknown-label ticket is counted, not exported, under --unsorted", %{opts: opts} do
      result = Export.page(Keyword.put(opts, :unsorted, true))
      refute 6 in numbers(result)
      assert elem(result, 1).unresolved_total == 1

      all = Export.page(opts)
      six = ticket(all, 6)
      assert six.epic.source == "unknown"
      assert "labels" in six.unknown
      refute Map.has_key?(six, :labels)
      assert ticket(all, 4).feature == "pag"
      assert ticket(all, 3).epic == %{key: "infra", source: "override:backfill-agent"}
    end
  end

  describe "fail closed (V-3, V-4, V-5)" do
    test "history unavailable is an error, never an empty list" do
      health = ProviderHealth.new(1, :unavailable, false, failure: :history_corrupt)
      assert Export.page(opts([row(1)], history: fn -> {:error, health} end)) == {:error, "history unavailable (history_corrupt)"}
    end

    # A partial History would make --unsorted look smaller than it is.
    test "an incomplete history backfill refuses" do
      health = healthy(complete?: false, failure: :backfill_pending)
      history = fn -> {:ok, %{rows: %{1 => row(1)}, health: health, repository: "o/r"}} end

      assert {:error, "history backfill incomplete; run after the one-time backfill finishes"} = Export.page(opts([row(1)], history: history))
    end

    test "unavailable overrides or features are errors, never 'none'" do
      health = ProviderHealth.new(1, :unavailable, false, failure: :journal_corrupt)

      assert Export.page(opts([row(1)], overrides: fn -> {:error, health} end)) == {:error, "epic overrides unavailable (journal_corrupt)"}
      assert Export.page(opts([row(1)], features: fn -> {:error, health} end)) == {:error, "features unavailable (journal_corrupt)"}
      assert Export.page(opts([row(1)], epics: fn -> {:error, :settings_loading} end)) == {:error, "epic config unavailable (settings_loading)"}
    end
  end

  describe "bodies (V-6, V-7)" do
    test "a held body is sanitised, redacted, capped and aged from its fetch time" do
      token = "ghp_" <> String.duplicate("A1", 18)
      body = "Fix\e[31m red " <> token <> " " <> String.duplicate("a", 2_000)
      fetched_at = DateTime.to_unix(@now, :millisecond) - 90_005_000
      result = Export.page(opts([row(1)], issue_body: fn 1 -> {:ok, %{data: %{"body" => body}, fetched_at_ms: fetched_at}} end))
      held = ticket(result, 1).body

      refute held.excerpt =~ "\e"
      refute held.excerpt =~ "ghp_A1"
      assert held.excerpt =~ "[REDACTED:ghp]"
      assert String.length(held.excerpt) <= 1_600
      assert held.truncated
      assert held.age_ms == 90_005_000
      assert held.observed_at == DateTime.from_unix!(fetched_at, :millisecond)
    end

    test "an unheld, keyless or oversized body is unknown, not empty" do
      for held <- [:miss, {:ok, %{data: %{"title" => "t"}, fetched_at_ms: 1}}, {:ok, %{data: %{"body" => String.duplicate("a", 300_000)}, fetched_at_ms: 1}}] do
        {:ok, page} = result = Export.page(opts([row(1)], issue_body: fn 1 -> held end))
        one = ticket(result, 1)

        refute Map.has_key?(one, :body)
        assert "body" in one.unknown
        assert page.sources.issue_bodies.held == 0
        assert page.sources.issue_bodies.state == :none_held
      end
    end

    test "a held body without a fetch timestamp omits its missing age facts" do
      {:ok, _page} = result = Export.page(opts([row(1)], issue_body: fn 1 -> {:ok, %{data: %{"body" => "held"}, fetched_at_ms: nil}} end))
      one = ticket(result, 1)

      assert one.body == %{excerpt: "held", truncated: false}
      assert "body.observed_at" in one.unknown
      assert "body.age_ms" in one.unknown
    end

    # Only the head of a long body is sanitised, so the cut must neither change
    # an ordinary excerpt nor let a secret the cut leaves open through.
    test "a long body gives the same excerpt as sanitising it whole, and no open key block leaks" do
      prose = Enum.map_join(1..2_000, "\n", &"line #{&1} of the ticket body")
      {:ok, whole, true} = Aiur.DisplaySanitizer.sanitize_projection(prose, 1_600, input_byte_limit: 262_144, redact_urls: true, redact_environment: true)
      reader = fn 1 -> {:ok, %{data: %{"body" => prose}, fetched_at_ms: 0}} end

      assert ticket(Export.page(opts([row(1)], issue_body: reader)), 1).body == %{
               excerpt: whole,
               truncated: true,
               observed_at: DateTime.from_unix!(0, :millisecond),
               age_ms: DateTime.to_unix(@now, :millisecond)
             }

      key = Enum.map_join(1..120, "\n", fn _ -> "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7" end)
      body = String.duplicate("context ", 100) <> "\n-----BEGIN PRIVATE KEY-----\n" <> key <> "\n-----END PRIVATE KEY-----\n"
      excerpt = ticket(Export.page(opts([row(1)], issue_body: fn 1 -> {:ok, %{data: %{"body" => body}, fetched_at_ms: 0}} end)), 1).body.excerpt

      assert excerpt =~ "[REDACTED:credential]"
      refute excerpt =~ "MIIEvQ"
    end

    test "a multibyte body is not marked truncated before its character excerpt limit" do
      body = String.duplicate("😀", 1_600)
      one = ticket(Export.page(opts([row(1)], issue_body: fn 1 -> {:ok, %{data: %{"body" => body}, fetched_at_ms: 0}} end)), 1)

      assert one.body.excerpt == body
      refute one.body.truncated
    end

    # GitHub sends `"body": null` for an empty description: that is known empty.
    test "a held null body is an empty excerpt and counts as held" do
      reader = fn
        1 -> {:ok, %{data: %{"body" => nil}, fetched_at_ms: DateTime.to_unix(@now, :millisecond)}}
        2 -> :miss
      end

      {:ok, page} = result = Export.page(opts([row(1), row(2)], issue_body: reader))

      assert ticket(result, 1).body.excerpt == ""
      refute "body" in ticket(result, 1).unknown
      assert "body" in ticket(result, 2).unknown
      assert page.sources.issue_bodies == %{state: :partial, held: 1, of: 2, retention_hours: 72}
    end
  end

  describe "missing facts (V-8, V-9)" do
    test "unknown facts are absent and listed; known absence is nil" do
      rows = [
        row(1, title: :unknown),
        row(2, lifecycle: %Lifecycle{state: :closed, state_reason: :unknown}),
        row(3, labels_complete: :unknown),
        row(4, lifecycle: %Lifecycle{state: :open, state_reason: :none}),
        row(7, pr_number: :none),
        row(8, pr_number: :unknown),
        row(9, pr_number: 415)
      ]

      result = Export.page(opts(rows))

      for {number, key} <- [{1, :title}, {2, :state_reason}, {3, :labels_complete}, {8, :pr_number}] do
        record = ticket(result, number)
        refute Map.has_key?(record, key), "##{number} should not carry #{key}"
        assert Atom.to_string(key) in record.unknown
      end

      assert ticket(result, 4).state_reason == nil
      refute "state_reason" in ticket(result, 4).unknown
      assert ticket(result, 7).pr_number == nil
      refute "pr_number" in ticket(result, 7).unknown
      assert ticket(result, 9).pr_number == 415
      assert ticket(result, 9).unknown == ["body"]
    end
  end

  describe "paging (V-10)" do
    test "the cursor walks every ticket once and totals cover all pages" do
      opts = opts(Enum.map(1..5, &row/1), unsorted: true, limit: 2)

      assert [{[1, 2], 2}, {[3, 4], 4}, {[5], nil}] ==
               for(after_number <- [0, 2, 4], do: Export.page(Keyword.put(opts, :after, after_number)))
               |> Enum.map(fn {:ok, page} = result ->
                 assert page.matching_total == 5
                 {numbers(result), page.next_after}
               end)

      # The stores change between pages: an insert after the cursor is still reached.
      changed = opts([row(1), row(2, labels: ["bug"]), row(3), row(4), row(5), row(6)], unsorted: true, limit: 2, after: 4)
      assert numbers(Export.page(changed)) == [5, 6]
    end

    test "an exactly full last page has no next cursor" do
      assert {:ok, %{next_after: nil}} = Export.page(opts([row(1), row(2)], limit: 2))
    end
  end

  # V-11: future-regression guard. The export must never fall back to a
  # GitHub read for a missing body; it passes on the first commit by design.
  test "the export modules reference no GitHub read path" do
    for path <- ["lib/aiur/build_order/history/export.ex", "lib/aiur/history_cli.ex"],
        forbidden <- ["Aiur.GitHub.Issues", "Aiur.GitHub.Transport", "Aiur.GitHub.ReadCache", "Aiur.GitHub.ResourceFetch", "request_fun"] do
      refute File.read!(path) =~ forbidden, "#{path} references #{forbidden}"
    end
  end

  test "an old healthy observation reports its real age (V-14)" do
    old = ProviderHealth.new(3, :healthy, true, observed_at: DateTime.add(@now, -7_200, :second))
    {:ok, page} = Export.page(opts([row(1)], history: fn -> {:ok, %{rows: %{1 => row(1)}, health: old, repository: "o/r"}} end))

    assert page.sources.history.freshness == :current
    assert page.sources.history.age_ms == 7_200_000
  end

  test "a long line without line breaks is cut at a word, and an unbroken one is still capped" do
    for body <- [String.duplicate("word ", 1_000), String.duplicate("a", 5_000)] do
      one = ticket(Export.page(opts([row(1)], issue_body: fn 1 -> {:ok, %{data: %{"body" => body}}} end)), 1)
      held = one.body

      assert held.truncated
      assert String.length(held.excerpt) in 1_595..1_600
      refute Map.has_key?(held, :observed_at)
      refute Map.has_key?(held, :age_ms)
      assert "body.observed_at" in one.unknown
      assert "body.age_ms" in one.unknown
    end
  end

  # Redaction can shrink the sanitised head below the excerpt limit; the rest
  # of the body was still never shown, so the excerpt is truncated.
  test "a body cut before sanitising is truncated even when its excerpt is short" do
    body = Enum.map_join(1..40, "\n", &"https://example.com/#{&1}/#{String.duplicate("p", 200)}")
    held = ticket(Export.page(opts([row(1)], issue_body: fn 1 -> {:ok, %{data: %{"body" => body}}} end)), 1).body

    assert String.length(held.excerpt) < 1_600
    assert held.truncated
  end

  test "labels that sanitise to nothing are dropped and an unobserved row says so" do
    result = Export.page(opts([row(1, labels: ["bug", "\e", "  "], observed_at: :unknown)]))
    one = ticket(result, 1)

    assert one.labels == ["bug"]
    assert "observed_at" in one.unknown
    refute Map.has_key?(one, :observed_at)
  end

  test "a stale feature store exports with its freshness, and an unreadable reply fails closed" do
    stale = ProviderHealth.new(3, :stale, true, observed_at: @observed)
    features = fn -> {:ok, %{owners: %{}, features: %{}, health: stale}} end
    {:ok, page} = Export.page(opts([row(1)], features: features))
    assert %{state: :stale, freshness: :stale, age_ms: 5_000} = page.sources.features

    assert Export.page(opts([row(1)], history: fn -> :garbage end)) == {:error, "history unavailable (invalid_read)"}
    no_failure = ProviderHealth.new(1, :unavailable, false)
    assert Export.page(opts([row(1)], features: fn -> {:error, no_failure} end)) == {:error, "features unavailable (unavailable)"}
  end

  # V-15: the agent tool calls page/1 without the launcher's argument checks.
  test "page/1 validates its own options" do
    for bad <- [[limit: 0], [limit: 501], [after: -1], [limit: "5"], [unsorted: "yes"]] do
      assert {:error, _reason} = Export.page(opts([row(1)], bad))
    end
  end

  # V-16: measurements with loose bounds. Without bodies the bound catches a
  # quadratic filter or resolve; with 50 KB bodies it catches sanitising whole
  # bodies (about 250 ms each under load, so 500 would take minutes).
  test "a 500-ticket page over 10,000 rows stays fast" do
    rows = Enum.map(1..10_000, &row/1)
    {bare, {:ok, _envelope}} = :timer.tc(fn -> Aiur.HistoryCLI.build(opts(rows, unsorted: true, limit: 500)) end)

    body = String.duplicate("word ", 320) <> String.duplicate("\nmore of a long ticket body", 2_000)
    reader = fn _number -> {:ok, %{data: %{"body" => body}, fetched_at_ms: DateTime.to_unix(@now, :millisecond)}} end
    {held, {:ok, envelope}} = :timer.tc(fn -> Aiur.HistoryCLI.build(opts(rows, unsorted: true, limit: 500, issue_body: reader)) end)
    bytes = byte_size(Jason.encode!(envelope))

    IO.puts("history export V-16: #{div(bare, 1_000)} ms without bodies; #{div(held, 1_000)} ms and #{bytes} bytes with 500 held bodies")
    assert length(envelope["data"]["tickets"]) == 500
    assert bare < 8_000_000
    assert held < 30_000_000
  end
end
