defmodule VoiceConverse.BriefingTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.Briefing

  @now ~U[2026-10-10 12:00:00Z]

  defp f(value, opts \\ []) do
    %{value: value, observed_at: Keyword.get(opts, :at, @now), max_age_s: Keyword.get(opts, :max_age_s)}
  end

  defp card(overrides \\ []) do
    struct(
      %Briefing{
        summary: f("Adding retry to the webhook sender."),
        current_task: f("Writing the backoff test, because the first version retried forever."),
        next_steps: f(["open the PR", "ask for review"]),
        waiting_on: f("CI"),
        questions: f(["Should retries cap at 5?"])
      },
      overrides
    )
  end

  defp protected_lines(text),
    do: for(l <- String.split(text, "\n"), l =~ ~r/^(Summary|Doing now|Waiting on|Questions)/, do: l)

  describe "render/2 budget" do
    # The assistant must never lose an operator question or the current task to the budget:
    # a silent cut there is worse than a large block. Seeded table instead of StreamData (no dep).
    test "render keeps protected fields under budget (200 generated cases)" do
      :rand.seed(:exsss, {7, 11, 13})

      for _ <- 1..200 do
        words = fn n -> Enum.map_join(1..n, " ", fn _ -> Enum.random(~w(ci pr review flaky retry cap)) end) end
        list = fn n, w -> for _ <- 1..n, do: words.(w) end

        b =
          card(
            current_task: f(words.(:rand.uniform(200))),
            waiting_on: f(words.(:rand.uniform(100))),
            questions: f(list.(:rand.uniform(6), :rand.uniform(80))),
            next_steps: f(list.(:rand.uniform(8), :rand.uniform(60))),
            links: for(i <- 1..:rand.uniform(10), do: %{label: "L#{i}", url: "https://x.test/#{words.(5)}"}),
            extra:
              for(i <- 1..:rand.uniform(5), do: %{title: "X#{i}", text: words.(:rand.uniform(100)), observed_at: @now})
          )

        budget = :rand.uniform(1_500)
        {text, meta} = Briefing.render(b, budget: budget, now: @now)
        {full, _} = Briefing.render(b, budget: 1_000_000, now: @now)

        assert protected_lines(text) == protected_lines(full)
        assert text =~ "Questions for you: " <> Enum.join(b.questions.value, "; ")
        assert meta.tokens == div(byte_size(text), 4)
        assert meta.over_budget == meta.tokens > budget
      end
    end

    test "over budget drops extra, then links, then next_steps beyond 3, in that order" do
      b =
        card(
          next_steps: f(Enum.map(1..6, &"step #{&1} #{String.duplicate("x", 40)}")),
          links: [%{label: "PR", url: "https://x.test/" <> String.duplicate("p", 200)}],
          extra: [%{title: "CI", text: String.duplicate("c", 200), observed_at: @now}]
        )

      full = elem(Briefing.render(b, budget: 1_000_000, now: @now), 1).tokens

      assert {_, %{dropped: [], over_budget: false}} = Briefing.render(b, budget: full, now: @now)

      {text, meta} = Briefing.render(b, budget: full - 1, now: @now)
      assert meta.dropped == [:extra]
      refute text =~ "CI: "
      assert text =~ "Links: "

      {text, meta} = Briefing.render(b, budget: meta.tokens - 1, now: @now)
      assert meta.dropped == [:extra, :links]
      refute text =~ "Links: "
      assert text =~ "step 6"

      {text, meta} = Briefing.render(b, budget: meta.tokens - 1, now: @now)
      assert meta.dropped == [:extra, :links, :next_steps]
      assert text =~ "step 3"
      refute text =~ "step 4"
      assert meta.over_budget == false
    end

    test "protected fields alone over budget stay whole and report over_budget" do
      question = String.duplicate("Should we ship the migration tonight? ", 100)
      {text, meta} = Briefing.render(card(questions: f([question])), budget: 50, now: @now)

      assert text =~ question
      assert meta.over_budget
      assert meta.tokens > 50
    end
  end

  describe "render/2 staleness and gaps" do
    test "stale field shows age: 15 minutes old with max_age_s 120" do
      b = card(waiting_on: f("CI", at: DateTime.add(@now, -15 * 60), max_age_s: 120))
      {text, _} = Briefing.render(b, now: @now)
      assert text =~ "Waiting on: CI (as of 15 min ago)"
    end

    test "a field within max_age_s renders as current" do
      b = card(waiting_on: f("CI", at: DateTime.add(@now, -60), max_age_s: 120))
      {text, _} = Briefing.render(b, now: @now)
      assert text =~ "Waiting on: CI\n"
      refute text =~ "as of"
    end

    test "max_age_s nil never renders an age, however old" do
      b = card(waiting_on: f("CI", at: DateTime.add(@now, -7 * 86_400)))
      {text, _} = Briefing.render(b, now: @now)
      refute text =~ "as of"
    end

    # "No data" must not read as "nothing to wait on": the assistant would tell the operator
    # the agent is idle when the host simply has no answer.
    test "a missing field is stated as not reported, distinct from an empty one" do
      {text, _} = Briefing.render(card(waiting_on: nil, questions: f([]), gaps: ["no note yet"]), now: @now)
      assert text =~ "Waiting on: not reported"
      assert text =~ "Questions for you: none"
      assert text =~ "Gaps: no note yet"
    end

    test "a field whose value is nil is not reported, not a crash or a blank" do
      {text, _} = Briefing.render(card(waiting_on: f(nil, max_age_s: 60)), now: @now)
      assert text =~ "Waiting on: not reported\n"
    end
  end

  describe "diff/2" do
    test "diff of equal briefings is empty" do
      assert Briefing.diff(card(), card()) == []
    end

    # A long session refreshes the card often; only the changed line may reach the provider.
    test "a changed waiting_on yields one line, not the whole card" do
      assert Briefing.diff(card(), card(waiting_on: f("review from Sam"))) == ["Waiting on: review from Sam"]
    end

    test "a refresh that changes only version, observed_at or age is empty" do
      old = card(waiting_on: f("CI", at: @now, max_age_s: 60))
      new = %{card(waiting_on: f("CI", at: DateTime.add(@now, 3_600), max_age_s: 60)) | version: 9}
      assert Briefing.diff(old, new) == []
    end

    # Hosts may send several extras with one title (two "PR" lines); a refresh must stay silent.
    test "equal briefings with duplicate extra titles diff empty and render both texts" do
      extra = for t <- ["#1 green", "#2 red"], do: %{title: "PR", text: t, observed_at: @now}
      assert Briefing.diff(card(extra: extra), card(extra: extra)) == []
      assert elem(Briefing.render(card(extra: extra), now: @now), 0) =~ "PR: #1 green; #2 red"
      md = Briefing.from_markdown("## Notes\na\n## Notes\nb\n", @now)
      assert Briefing.diff(md, md) == []
    end

    test "a field that became empty or was removed says none now" do
      old = card(links: [%{label: "PR", url: "https://x.test/1"}])
      new = card(questions: f([]))
      assert Briefing.diff(old, new) == ["Questions for you: none now", "Links: none now"]
    end
  end

  describe "from_markdown/2" do
    @md """
    # Summary
    Adding retry to the webhook sender.

    ## Doing now
    Writing the backoff test.

    ## Next
    - open the PR
    - ask for review

    ## Waiting on
    CI

    ### Questions for you
    1. Should retries cap at 5?
    """

    test "maps the five headings and stamps observed_at" do
      b = Briefing.from_markdown(@md, @now)
      assert b.summary == f("Adding retry to the webhook sender.")
      assert b.current_task == f("Writing the backoff test.")
      assert b.next_steps == f(["open the PR", "ask for review"])
      assert b.waiting_on == f("CI")
      assert b.questions == f(["Should retries cap at 5?"])
      assert b.gaps == []
      assert b.extra == []
    end

    test "a missing heading becomes a gap, not an error or an empty value" do
      b = Briefing.from_markdown(String.replace(@md, "## Waiting on\nCI\n", ""), @now)
      assert b.waiting_on == nil
      assert b.gaps == [~s(no "Waiting on" section)]
      assert elem(Briefing.render(b, now: @now), 0) =~ "Waiting on: not reported"
    end

    test "a # line inside a fenced code block stays in its section" do
      b = Briefing.from_markdown(String.replace(@md, "CI\n", "CI\n```bash\n# rerun CI\ngh run rerun\n```\n"), @now)
      assert b.waiting_on.value =~ "# rerun CI"
      assert b.questions == f(["Should retries cap at 5?"])
      assert b.extra == []
    end

    test "an unknown heading goes to extra" do
      b = Briefing.from_markdown(@md <> "\n## PR status\nGreen on main.\n", @now)
      assert b.extra == [%{title: "PR status", text: "Green on main.", observed_at: @now}]
    end

    test "each alias maps to its field, ignoring case, level and a trailing colon" do
      for {key, names} <- VoiceConverse.Briefing.Markdown.aliases(), name <- names do
        b = Briefing.from_markdown("#### #{String.upcase(name)}:\nx\n", @now)
        assert Map.fetch!(b, key).value in ["x", ["x"]], "alias #{inspect(name)} did not map to #{key}"
      end
    end
  end
end
