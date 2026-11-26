defmodule Aiur.OverlapReviewer.MatcherTest do
  use ExUnit.Case, async: true

  alias Aiur.OverlapReviewer.Matcher

  test "extends an open PR ahead of an equally relevant issue and reports the supporting references" do
    subject = Matcher.document(:issue, 20, "Cache webhook delivery validation", "Touch `src/webhooks/validator.ex` and `Validator.validate/2`.")
    duplicate_ticket = Matcher.document(:issue, 11, "Webhook delivery validation cache", "")
    open_pr = Matcher.document(:open_pr, 12, "Webhook delivery validation cache", "Uses `src/webhooks/validator.ex` and `Validator.validate/2`.", [11])

    assert %{
             action: :extend,
             target: %{kind: :open_pr, number: 12},
             evidence: %{
               files: ["src/webhooks/validator.ex"],
               symbols: ["Validator.validate/2"],
               title_terms: ~w(cache delivery validation webhook)
             }
           } = Matcher.review(subject, [duplicate_ticket, open_pr])
  end

  test "folds work into a matching recent merge or an existing ticket" do
    subject = Matcher.document(:issue, 14, "Explain dispatch budgets", nil)
    merge = Matcher.document(:merged_pr, 10, "Explain dispatch budgets", nil)
    existing = Matcher.document(:issue, 11, "Explain dispatch budgets", nil)

    assert %{action: :fold, target: %{kind: :merged_pr, number: 10}} = Matcher.review(subject, [existing, merge])
    assert %{action: :fold, target: %{kind: :issue, number: 11}} = Matcher.review(subject, [existing])
  end

  test "matches differently titled work when it names the same file and function" do
    subject = Matcher.document(:issue, 20, "Record trace receipt", "Change src/webhooks/validator.ex and Validator.write_receipt/3.")
    pull = Matcher.document(:open_pr, 21, "Prevent double delivery", "Adjust src/webhooks/validator.ex and Validator.write_receipt/3.")

    assert %{
             action: :extend,
             target: %{number: 21},
             evidence: %{files: ["src/webhooks/validator.ex"], symbols: ["Validator.write_receipt/3"], title_terms: []}
           } = Matcher.review(subject, [pull])
  end

  test "builds when the only strong match is the ticket's own PR and another ticket mentions one shared file" do
    subject = Matcher.document(:issue, 10, "Cache webhook delivery validation", "Touches src/webhooks/validator.ex.")
    own_pr = Matcher.document(:open_pr, 11, "Cache webhook delivery validation", "", [10])
    unrelated = Matcher.document(:issue, 12, "Webhook delivery history", "References src/webhooks/validator.ex.")

    assert %{action: :build, target: nil, evidence: %{title_terms: [], files: [], symbols: []}} = Matcher.review(subject, [subject, own_pr, unrelated])
  end

  test "lists seeded ticket and PR overlaps within and across features without listing an issue against its own PR" do
    title = "Record cold start latency"
    first = Matcher.document(:issue, 1, title, nil)
    second = Matcher.document(:issue, 2, title, nil)
    other_feature_pr = Matcher.document(:open_pr, 9, title, nil, [1, 8])
    unrelated = Matcher.document(:issue, 7, "Publish launch announcements", nil)

    assert [
             %{left: %{number: 1}, right: %{number: 2}, features: ["metrics"], scope: :within, evidence: %{title_terms: ~w(cold latency record start)}},
             %{left: %{number: 2}, right: %{number: 9}, features: ["metrics", "startup"], scope: :across}
           ] =
             Matcher.feature_scan(
               [other_feature_pr, second, unrelated, first],
               %{1 => ["metrics"], 2 => ["metrics"], 7 => ["metrics"], 8 => ["startup"]}
             )
  end
end
