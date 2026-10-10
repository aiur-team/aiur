defmodule AiurWeb.Build.URLStateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias AiurWeb.Build.URLState

  test "parse keeps every valid design key in canonical order" do
    q = "view=gantt&trees=1&live=min&span=7&feature=f-docs&fmode=compact&epic=bugs,docs&model=claude&tstate=in+progress&astate=error,retries,command&ticket=2748"

    assert URLState.parse(URI.decode_query(q)) == %{
             view: "gantt",
             span: 7,
             feature: "f-docs",
             fmode: "compact",
             epic: ["bugs", "docs"],
             model: ["claude"],
             tstate: ["in progress"],
             astate: ["error", "retries", "command"],
             live_min: true,
             trees: true,
             ticket: "2748"
           }

    assert canonical(q) == q
    assert canonical("span=7&view=gantt") == "view=gantt&span=7"
    assert canonical("") == ""
  end

  test "span accepts only complete supported integers" do
    assert canonical("span=07") == "span=7"
    for value <- ["7.0", "4", "-1", " 7", "0x7"], do: assert(URLState.parse(%{"span" => value}).span == 1)
  end

  test "invalid and non-string values are dropped" do
    assert canonical("view=Gantt&span=4&fmode=compact&astate=bogus,active,active&model=none&ticket=AIUR-12&zoom=2&models=7&example=dense") == "astate=active"

    for key <- ~w(view span feature fmode epic model tstate astate live trees ticket), value <- [nil, [], %{}, 1] do
      assert URLState.parse(%{key => value}) == URLState.defaults()
    end

    assert canonical("feature=%3Cscript%3E&epic=%zz") == ""
    assert canonical("feature=" <> String.duplicate("x", 65)) == ""
    assert canonical("feature=" <> String.duplicate("x", 64)) == "feature=" <> String.duplicate("x", 64)
  end

  test "models accept unknown shape-valid keys" do
    assert canonical("model=zz-new,claude,openrouter,muse") == "model=zz-new,claude,openrouter,muse"
    for value <- ["Claude", "-x", String.duplicate("x", 33), "none"], do: assert(URLState.parse(%{"model" => value}).model == [])
    assert canonical("tstate=not+planned") == "tstate=not+planned"
  end

  test "lists preserve order, deduplicate, drop empties and cap at 32" do
    assert canonical("astate=parked,,paused,parked") == "astate=parked,paused"
    assert canonical("astate=paused,parked") == "astate=paused,parked"
    assert canonical("tstate=in+progress,queued") == "tstate=in+progress,queued"
    values = Enum.map(1..40, &"epic-#{&1}")
    assert URLState.parse(%{"epic" => Enum.join(values, ",")}).epic == Enum.take(values, 32)
  end

  test "ticket keeps unknown positive ids and canonicalizes leading zeros" do
    assert canonical("ticket=007") == "ticket=7"
    assert canonical("ticket=99999") == "ticket=99999"
    for value <- ["0", "-3", "+7", "12a", "#12", "12345678901"], do: assert(URLState.parse(%{"ticket" => value}).ticket == nil)
  end

  test "legacy presets keep now-band order and use one group for mixed conditions" do
    cases = [
      {"v=1", ""},
      {"scope=all", ""},
      {"scope=none", ""},
      {"v=1&scope=unfinished", "tstate=in+progress,queued,held,blocked"},
      {"conditions=active", "astate=active"},
      {"conditions=alert", "astate=error,retries,command"},
      {"conditions=paused", "astate=paused,parked"},
      {"conditions=stuck,alert", "astate=error,retries,command"},
      {"conditions=active,paused", "astate=active,paused,parked"},
      {"conditions=active,queued", "tstate=in+progress,queued,held,blocked"},
      {"scope=all&conditions=finished&sort=units:age:desc", "tstate=merged,failed"},
      {"conditions=active,finished,queued", "tstate=merged,failed,in+progress,queued,held,blocked"},
      {"v=999&conditions=alert", ""}
    ]

    for {query, expected} <- cases do
      params = URI.decode_query(query)
      assert URLState.legacy?(params)
      assert params |> URLState.legacy_preset() |> URLState.parse() |> URLState.to_query() == expected
    end

    refute URLState.legacy?(%{"sort" => "fleet:age:desc"})
  end

  property "canonical state and query are fixed points" do
    check all(
            params <-
              map(
                list_of(
                  tuple(
                    {member_of(~w(view span feature fmode epic model tstate astate live trees ticket unknown)),
                     one_of([string(:printable), member_of(["gantt", "compact", "07", "active,active", "min", "1", "f-docs"])])}
                  )
                ),
                &Map.new/1
              ),
            max_runs: 200
          ) do
      state = URLState.parse(params)
      query = URLState.to_query(state)
      assert URLState.parse(URI.decode_query(query)) == state
      assert canonical(query) == query
    end
  end

  property "200 generated valid states round trip every field" do
    check all(
            view <- member_of(["graph", "gantt", "list"]),
            span <- member_of([1, 2, 3, 5, 7, 10, 14, 21, 30]),
            feature <- member_of([nil, "f-docs", "Outside-window._1"]),
            compact <- boolean(),
            trees <- boolean(),
            live_min <- boolean(),
            epics <- ordered_subset(["bugs", "docs", "epic-3"]),
            models <- ordered_subset(["claude", "zz-new", "muse"]),
            tstates <- ordered_subset(["merged", "in progress", "not planned", "queued"]),
            astates <- ordered_subset(~w(active error retries command paused parked none)),
            ticket <- member_of([nil, "7", "99999"]),
            max_runs: 200
          ) do
      state = %{
        view: view,
        span: span,
        feature: feature,
        fmode: if(feature && compact, do: "compact", else: "focus"),
        trees: trees,
        live_min: live_min,
        epic: epics,
        model: models,
        tstate: tstates,
        astate: astates,
        ticket: ticket
      }

      assert URLState.parse(URI.decode_query(URLState.to_query(state))) == state
    end
  end

  test "golden parity with the unmodified design and declared differences" do
    fixture = File.read!(Path.expand("../../fixtures/build_home/url_cases.json", __DIR__)) |> Jason.decode!()

    for row <- fixture["cases"] do
      params = URI.decode_query(row["query"])
      params = if URLState.legacy?(params), do: Map.merge(URLState.legacy_preset(params), Map.drop(params, ~w(v scope conditions))), else: params
      assert params |> URLState.parse() |> URLState.to_query() == row["canonical"]
      assert canonical(row["canonical"]) == row["canonical"]
      if row["differs"], do: assert(row["differs"] != ""), else: assert(row["canonical"] == row["design_output"])
    end
  end

  defp ordered_subset(values), do: map(list_of(member_of(values), max_length: 10), &Enum.uniq/1)

  defp canonical(query), do: query |> URI.decode_query() |> URLState.parse() |> URLState.to_query()
end
