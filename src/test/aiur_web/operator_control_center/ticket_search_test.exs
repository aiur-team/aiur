defmodule AiurWeb.OperatorControlCenter.TicketSearchTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.TicketSearch

  describe "terms/1" do
    test "tokenises on punctuation and case so a raw query never reaches a comparison" do
      assert TicketSearch.terms("Retry-Storm: ORCHESTRATOR!") == ["retry", "storm", "orchestrator"]
    end

    test "repeats and a pasted paragraph are bounded, because every term costs a full index scan" do
      assert TicketSearch.terms("retry retry retry") == ["retry"]
      assert length(TicketSearch.terms(Enum.map_join(1..50, " ", &"term#{&1}"))) == 8
    end

    test "decomposed accents stay inside their word, so a macOS query matches GitHub's composed text" do
      nfd = :unicode.characters_to_nfd_binary("état café")

      assert TicketSearch.terms(nfd) == TicketSearch.terms("état café")
      assert [%{identifier: "41"}] = TicketSearch.filter([row("41", "État du café")], nfd)
    end

    test "a blank or punctuation-only query has no terms, which is how the panel detects 'not searching'" do
      assert TicketSearch.terms("") == []
      assert TicketSearch.terms("   ") == []
      assert TicketSearch.terms("--- ///") == []
      assert TicketSearch.terms(nil) == []
    end
  end

  describe "filter/2" do
    test "an empty query returns every row in its original order" do
      rows = [row("41", "Alpha"), row("42", "Beta")]

      assert TicketSearch.filter(rows, "") == rows
      assert TicketSearch.filter(rows, "   ") == rows
    end

    test "every term must match, across title and description in any order" do
      hit = row("41", "Retry the dispatch", "A storm of webhooks overwhelms the poller.")
      title_only = row("42", "Retry the dispatch", "Nothing else here.")
      body_only = row("43", "Unrelated", "A storm of webhooks.")

      assert [%{identifier: "41"}] = TicketSearch.filter([hit, title_only, body_only], "retry storm")
      assert [%{identifier: "41"}] = TicketSearch.filter([hit, title_only, body_only], "storm retry")
    end

    test "a title hit outranks a body hit, and a whole word outranks a partial" do
      body = row("41", "Unrelated work", "The retry budget is exhausted.")
      partial_title = row("42", "Retrying the dispatch", "Unrelated.")
      whole_title = row("43", "Retry budget", "Unrelated.")

      assert ["43", "42", "41"] =
               [body, partial_title, whole_title]
               |> TicketSearch.filter("retry")
               |> Enum.map(& &1.identifier)
    end

    test "ties keep the source order so the table never reshuffles between keystrokes" do
      rows = [row("41", "Retry budget"), row("42", "Retry budget")]

      assert ["41", "42"] = rows |> TicketSearch.filter("retry") |> Enum.map(& &1.identifier)
    end

    test "a number matches the ticket ID, and the ID hit outranks a text hit on the same number" do
      target = row("1821", "Wake cleared dependencies")
      mention = row("42", "Follow-up to 1821", "See 1821.")

      assert ["1821", "42"] = [mention, target] |> TicketSearch.filter("1821") |> Enum.map(& &1.identifier)
    end

    test "a prefix finds the whole word, so the list narrows while the operator is still typing" do
      rows = [row("41", "Orchestrator restart"), row("42", "Unrelated")]

      assert [%{identifier: "41"}] = TicketSearch.filter(rows, "orchestr")
    end

    test "one typo still finds the ticket: a substitution, a dropped letter, or a transposition" do
      rows = [row("41", "Orchestrator restart")]

      assert [%{identifier: "41"}] = TicketSearch.filter(rows, "orchestratur")
      assert [%{identifier: "41"}] = TicketSearch.filter(rows, "orchestrtor")
      assert [%{identifier: "41"}] = TicketSearch.filter(rows, "orcehstrator")
    end

    test "typo tolerance is bounded: two edits, or a typo in a short term, do not match" do
      rows = [row("41", "Orchestrator restart"), row("42", "Wake dependencies")]

      # Two substitutions is a different word, not a slip.
      assert TicketSearch.filter(rows, "orchestrutur") == []
      # Short terms are where fuzz turns into noise: "wale" must not find "wake".
      assert TicketSearch.filter(rows, "wale") == []
    end

    test "a nonsense query matches nothing rather than degrading to everything" do
      rows = [row("41", "Retry budget", "Storms of webhooks."), row("42", "Documentation refresh")]

      assert TicketSearch.filter(rows, "zzzzqqqq") == []
      assert TicketSearch.filter(rows, "retry zzzzqqqq") == []
    end

    test "a row indexed once by the presenter scores the same as one indexed on demand" do
      indexed = TicketSearch.put_index(row("41", "Retry budget", "Storm of webhooks."))

      assert [^indexed] = TicketSearch.filter([indexed], "retry storm")
      assert [_row] = TicketSearch.filter([Map.delete(indexed, :search)], "retry storm")
    end

    test "a row with no title or description is searchable by ID and never crashes the filter" do
      bare = %{identifier: "41", title: nil, body_excerpt: nil}

      assert [^bare] = TicketSearch.filter([bare], "41")
      assert TicketSearch.filter([bare], "retry") == []
    end
  end

  defp row(identifier, title, body_excerpt \\ nil) do
    %{identifier: identifier, title: title, body_excerpt: body_excerpt}
  end
end
