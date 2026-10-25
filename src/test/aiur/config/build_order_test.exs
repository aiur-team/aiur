defmodule Aiur.Config.BuildOrderTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.GraphProjection.Options
  alias Aiur.BuildOrder.Settings
  alias Aiur.Config.Schema

  # The three surviving cadence keys deliberately have no fixed default any more.
  # They were constants chosen when the tracker polled every 5 seconds, and
  # asserting those constants here is what let them survive #2064 slowing the
  # tracker to 120 — the test encoded the bug. `nil` means "derive from the poll
  # interval", and the derivation itself is asserted in
  # `Aiur.BuildOrder.CadenceTest`.
  test "leaves the poll-derived cadences unset so they can be derived" do
    assert {:ok, settings} = Schema.parse(%{})

    assert settings.build_order.ticket_detail_freshness_ms == nil
    assert settings.build_order.graph_catalog_refresh_ms == nil
    assert settings.build_order.graph_catalog_labels_refresh_ms == nil
  end

  # The two settings that let viewing buy GitHub reads are gone from the schema.
  # A configuration that still carries them must keep loading — `cast/3` ignores
  # keys outside the permitted list — so an operator upgrading gets the new
  # behaviour rather than a daemon that will not boot.
  # Asserted as "loading them changes nothing", not as "the struct lacks the
  # field". `settings.build_order` is an Ecto struct with a closed field set, so
  # `refute Map.has_key?(struct, :anything)` is statically true and would pass
  # against a schema that had reinstated both keys under different names — or
  # against one that honoured them.
  test "a configuration still setting the deleted viewer cadences still loads" do
    assert {:ok, with_deleted} =
             Schema.parse(%{
               "build_order" => %{
                 "graph_selected_refresh_ms" => 15_000,
                 "graph_demand_refresh_ms" => 5_000
               }
             })

    assert {:ok, without} = Schema.parse(%{})

    assert with_deleted.build_order == without.build_order,
           "the deleted viewer cadences must be inert; honouring one would let viewing buy GitHub reads again"
  end

  test "uses bounded projection and ticket-detail defaults for everything else" do
    assert {:ok, settings} = Schema.parse(%{})

    assert settings.build_order.ticket_detail_max_entries == 32
    assert settings.build_order.ticket_detail_max_description_bytes == 16_384
    assert settings.build_order.ticket_history_limit == 50
    assert settings.build_order.ticket_history_max_identities == 100
    assert settings.build_order.ticket_history_stale_after_ms == 60_000
    assert settings.build_order.graph_refresh_timeout_ms == 30_000
    assert settings.build_order.graph_max_selected_roots == 32
    assert settings.build_order.graph_max_inflight == 4
  end

  test "accepts explicit projection and ticket-detail cache bounds" do
    assert {:ok, settings} =
             Schema.parse(%{
               "build_order" => %{
                 "ticket_detail_freshness_ms" => 10_000,
                 "ticket_detail_max_entries" => 12,
                 "ticket_detail_max_description_bytes" => 4_096,
                 "ticket_history_limit" => 12,
                 "ticket_history_max_identities" => 24,
                 "ticket_history_stale_after_ms" => 120_000,
                 "graph_catalog_refresh_ms" => 120_000,
                 "graph_catalog_labels_refresh_ms" => 900_000,
                 "graph_refresh_timeout_ms" => 20_000,
                 "graph_max_selected_roots" => 12,
                 "graph_max_inflight" => 2
               }
             })

    assert settings.build_order.ticket_detail_freshness_ms == 10_000
    assert settings.build_order.ticket_detail_max_entries == 12
    assert settings.build_order.ticket_detail_max_description_bytes == 4_096
    assert settings.build_order.ticket_history_limit == 12
    assert settings.build_order.ticket_history_max_identities == 24
    assert settings.build_order.ticket_history_stale_after_ms == 120_000
    assert settings.build_order.graph_catalog_refresh_ms == 120_000
    assert settings.build_order.graph_catalog_labels_refresh_ms == 900_000

    # The setting is inert unless it reaches the projection's policy, so pin
    # both halves of the wiring: Settings exports the key, and policy_options/1
    # maps it through rather than falling back to the default.
    assert Keyword.has_key?(Settings.build_order_graph_projection_options(), :catalog_labels_refresh_ms)

    policy =
      Options.policy_options(
        catalog_refresh_ms: 120_000,
        catalog_labels_refresh_ms: 900_000
      )

    assert policy.catalog_labels_refresh_ms == 900_000

    # And no configuration can make the expensive read outrun the catalog poll.
    clamped =
      Options.policy_options(
        catalog_refresh_ms: 120_000,
        catalog_labels_refresh_ms: 1_000
      )

    assert clamped.catalog_labels_refresh_ms == 120_000
    assert settings.build_order.graph_refresh_timeout_ms == 20_000
    assert settings.build_order.graph_max_selected_roots == 12
    assert settings.build_order.graph_max_inflight == 2
  end

  test "rejects unbounded or nonpositive ticket-detail cache configuration" do
    for attrs <- [
          %{"ticket_detail_freshness_ms" => 300_001},
          %{"ticket_detail_max_entries" => 101},
          %{"ticket_detail_max_description_bytes" => 16_385},
          %{"ticket_history_limit" => 101},
          %{"ticket_history_max_identities" => 101},
          %{"ticket_history_stale_after_ms" => 300_001},
          %{"ticket_history_limit" => 0},
          %{"ticket_detail_freshness_ms" => 0}
        ] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"build_order" => attrs})
      assert message =~ "build_order"
    end
  end

  test "rejects invalid projection bounds" do
    for attrs <- [
          %{"graph_catalog_refresh_ms" => 3_600_001},
          %{"graph_catalog_labels_refresh_ms" => 3_600_001},
          # A labels cadence faster than the catalog poll would make every poll
          # buy the ~26-point query — the regression #1766 exists to prevent.
          %{"graph_catalog_refresh_ms" => 60_000, "graph_catalog_labels_refresh_ms" => 59_999},
          %{"graph_refresh_timeout_ms" => 120_001},
          %{"graph_max_selected_roots" => 101},
          %{"graph_max_inflight" => 17}
        ] do
      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"build_order" => attrs})
      assert message =~ "build_order"
    end
  end

  defp epic(attrs \\ %{}) do
    Map.merge(%{"key" => "bugs", "label" => "Bugs", "hue" => 38, "icon" => "bug", "labels" => ["bug"]}, attrs)
  end

  defp parse_general_epics(epics), do: Schema.parse(%{"build_order" => %{"general_epics" => epics}})

  test "defaults are the design's four general epics, in design order" do
    assert {:ok, settings} = Schema.parse(%{})
    # DESIGN-E8 GENERAL, design-source/assets/build.js:96.
    assert Enum.map(settings.build_order.general_epics, &{&1.key, &1.label, &1.hue, &1.icon, &1.labels}) == [
             {"bugs", "Bugs", 38, "bug", ["bug"]},
             {"design", "Design", 312, "pen", ["design"]},
             {"infra", "Infra", 200, "server", ["refactor", "chore"]},
             {"docs", "Docs", 100, "docs", ["documentation"]}
           ]
  end

  test "defaults apply when the section exists without epics" do
    assert {:ok, settings} = Schema.parse(%{"build_order" => %{"graph_max_inflight" => 2}})
    assert Enum.map(settings.build_order.general_epics, & &1.key) == ~w(bugs design infra docs)
    assert settings.build_order.graph_max_inflight == 2
  end

  test "general_epics null means the defaults" do
    assert {:ok, settings} = parse_general_epics(nil)
    assert Enum.map(settings.build_order.general_epics, & &1.key) == ~w(bugs design infra docs)
  end

  test "guard: an empty list turns general epics off" do
    assert {:ok, settings} = parse_general_epics([])
    assert settings.build_order.general_epics == []
  end

  test "a configured list replaces the defaults and keeps its order" do
    assert {:ok, settings} = parse_general_epics([epic(%{"key" => "runtime", "labels" => []}), epic()])
    assert Enum.map(settings.build_order.general_epics, & &1.key) == ["runtime", "bugs"]
    assert hd(settings.build_order.general_epics).labels == []
  end

  test "an epic: matcher is refused with the parking reason" do
    assert {:error, {:invalid_workflow_config, message}} = parse_general_epics([epic(%{"labels" => ["  Epic:Bugs "]})])
    assert message == "build_order.general_epics.0.labels must not use the epic: prefix; IssueSync treats epic:* labels as deliberate parking and stops healing those tickets"
  end

  test "labels are trimmed, downcased and deduplicated" do
    assert {:ok, settings} = parse_general_epics([epic(%{"labels" => [" Bug ", "bug", "BUG", " Refactor "]})])
    assert hd(settings.build_order.general_epics).labels == ["bug", "refactor"]
  end

  test "a label in two epics is refused" do
    assert {:error, {:invalid_workflow_config, message}} = parse_general_epics([epic(), epic(%{"key" => "infra", "labels" => ["Bug"]})])
    assert message == ~s(build_order.general_epics label "bug" is in both bugs and infra; a label can place a ticket in one epic only)
  end

  test "duplicate keys are refused" do
    assert {:error, {:invalid_workflow_config, message}} = parse_general_epics([epic(), epic(%{"labels" => []})])
    assert message == ~s(build_order.general_epics key "bugs" is used by more than one epic)
  end

  test "unsorted is reserved" do
    assert {:error, {:invalid_workflow_config, message}} = parse_general_epics([epic(%{"key" => "unsorted"})])
    assert message == "build_order.general_epics.0.key is reserved for the column of tickets with no epic"
  end

  test "key format" do
    for key <- ["Bugs", "-x", "a b"] do
      assert {:error, {:invalid_workflow_config, message}} = parse_general_epics([epic(%{"key" => key})])
      assert message == "build_order.general_epics.0.key must be a lowercase identifier (letters, digits, dash, underscore)"
    end
  end

  test "hue bounds" do
    for {hue, reason} <- [{-1, "must be greater than or equal to 0"}, {360, "must be less than 360"}, {1.5, "is invalid"}] do
      assert {:error, {:invalid_workflow_config, message}} = parse_general_epics([epic(%{"hue" => hue})])
      assert message == "build_order.general_epics.0.hue " <> reason
    end

    for hue <- [0, 359] do
      assert {:ok, settings} = parse_general_epics([epic(%{"hue" => hue})])
      assert hd(settings.build_order.general_epics).hue == hue
    end
  end

  test "icon must be a design general-epic icon" do
    assert Schema.GeneralEpic.icons() == ~w(bug pen server docs)

    for icon <- ~w(layers unsorted rocket) do
      assert {:error, {:invalid_workflow_config, message}} = parse_general_epics([epic(%{"icon" => icon})])
      assert message == "build_order.general_epics.0.icon is invalid"
    end

    for icon <- Schema.GeneralEpic.icons() do
      assert {:ok, settings} = parse_general_epics([epic(%{"icon" => icon})])
      assert hd(settings.build_order.general_epics).icon == icon
    end
  end

  test "required fields" do
    for field <- ~w(key label hue icon) do
      assert {:error, {:invalid_workflow_config, message}} = parse_general_epics([Map.delete(epic(), field)])
      assert message == "build_order.general_epics.0.#{field} can't be blank"
    end
  end

  test "a blank label is refused" do
    for labels <- [["  "], [nil]] do
      assert {:error, {:invalid_workflow_config, message}} = parse_general_epics([epic(%{"labels" => labels})])
      assert message == "build_order.general_epics.0.labels must not contain a blank label"
    end
  end

  test "label control characters are refused" do
    for label <- ["Bugs" <> <<7>>, "Bugs" <> <<127>>] do
      assert {:error, {:invalid_workflow_config, message}} = parse_general_epics([epic(%{"label" => label})])
      assert message == "build_order.general_epics.0.label must not contain control characters"
    end
  end

  test "invalid children retain their indexed errors despite duplicate keys" do
    assert {:error, {:invalid_workflow_config, message}} = parse_general_epics([epic(), epic(%{"icon" => "rocket"})])
    assert message == "build_order.general_epics.1.icon is invalid"
  end

  test "malformed epic lists and matcher arrays return config errors" do
    for {value, expected} <- [
          {"bugs", "build_order.general_epics is invalid"},
          {["bugs"], "build_order.general_epics is invalid"},
          {[epic(%{"labels" => [1]})], "build_order.general_epics.0.labels is invalid"}
        ] do
      assert {:error, {:invalid_workflow_config, message}} = parse_general_epics(value)
      assert message == expected
    end
  end
end
