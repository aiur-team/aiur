defmodule Aiur.Config.Schema.AgentValidationTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema.AgentValidation
  alias Ecto.Changeset

  describe "normalize_issue_state/1" do
    test "lowercases the state name" do
      assert AgentValidation.normalize_issue_state("In Progress") == "in progress"
      assert AgentValidation.normalize_issue_state("TODO") == "todo"
    end
  end

  describe "normalize_routing_level/1" do
    test "passes through integers" do
      assert AgentValidation.normalize_routing_level(3) == 3
    end

    test "parses string integers" do
      assert AgentValidation.normalize_routing_level("3") == 3
      assert AgentValidation.normalize_routing_level("10") == 10
    end

    test "passes through non-parseable strings" do
      assert AgentValidation.normalize_routing_level("high") == "high"
    end

    test "passes through other types" do
      assert AgentValidation.normalize_routing_level(:atom) == :atom
    end
  end

  describe "normalize_state_limits/1" do
    test "returns empty map for nil" do
      assert AgentValidation.normalize_state_limits(nil) == %{}
    end

    test "lowercases state name keys" do
      result = AgentValidation.normalize_state_limits(%{"In Progress" => 2, todo: 1})
      assert result == %{"in progress" => 2, "todo" => 1}
    end
  end

  describe "validate_state_limits/2" do
    defp make_changeset(value) do
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: value}, [:limits])
    end

    test "accepts a valid state limits map" do
      cs = make_changeset(%{"todo" => 3}) |> AgentValidation.validate_state_limits(:limits)
      assert cs.valid?
    end

    test "rejects blank state names" do
      cs = make_changeset(%{"" => 1}) |> AgentValidation.validate_state_limits(:limits)
      refute cs.valid?
      assert {_, _} = hd(cs.errors)
    end

    test "rejects non-positive integer limits" do
      cs = make_changeset(%{"todo" => 0}) |> AgentValidation.validate_state_limits(:limits)
      refute cs.valid?
    end
  end

  describe "normalize_agent_routing/1" do
    test "returns empty map for nil" do
      assert AgentValidation.normalize_agent_routing(nil) == %{}
    end

    test "parses string complexity levels to integers" do
      result = AgentValidation.normalize_agent_routing(%{"4" => "claude", 5 => :codex})
      assert result == %{4 => "claude", 5 => "codex"}
    end
  end

  describe "normalize_complexity_prompts/1" do
    test "returns empty map for nil" do
      assert AgentValidation.normalize_complexity_prompts(nil) == %{}
    end

    test "parses string complexity levels to integers" do
      result =
        AgentValidation.normalize_complexity_prompts(%{"3" => "medium guidance", 5 => "be careful"})

      assert result == %{3 => "medium guidance", 5 => "be careful"}
    end
  end

  describe "validate_agent_routing/2" do
    defp make_routing_changeset(value) do
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: value}, [:routing])
    end

    test "accepts a valid routing map" do
      cs = make_routing_changeset(%{3 => "claude"}) |> AgentValidation.validate_agent_routing(:routing)
      assert cs.valid?
    end

    test "accepts routing with model segment" do
      cs = make_routing_changeset(%{2 => "codex:gpt-5.5"}) |> AgentValidation.validate_agent_routing(:routing)
      assert cs.valid?
    end

    test "accepts +remote routing on a remote-capable backend" do
      cs = make_routing_changeset(%{5 => "claude+remote"}) |> AgentValidation.validate_agent_routing(:routing)
      assert cs.valid?
    end

    test "accepts routing with valid effort segment" do
      cs = make_routing_changeset(%{3 => "codex::high"}) |> AgentValidation.validate_agent_routing(:routing)
      assert cs.valid?
    end

    test "rejects non-positive complexity levels" do
      cs = make_routing_changeset(%{0 => "claude"}) |> AgentValidation.validate_agent_routing(:routing)
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :routing)
    end

    test "rejects unknown backend" do
      cs = make_routing_changeset(%{3 => "unknown-llm"}) |> AgentValidation.validate_agent_routing(:routing)
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :routing)
    end

    test "rejects +remote on non-remote-capable backend (codex)" do
      cs = make_routing_changeset(%{3 => "codex+remote"}) |> AgentValidation.validate_agent_routing(:routing)
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :routing)
    end

    test "rejects invalid effort for backend" do
      cs = make_routing_changeset(%{3 => "claude-repl::invalid-effort"}) |> AgentValidation.validate_agent_routing(:routing)
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :routing)
    end

    # #3961: Claude accepts no effort segment. The error says so and names the
    # value to write, instead of "valid efforts: []".
    test "explains that claude takes no effort segment" do
      cs = make_routing_changeset(%{3 => "claude:sonnet:medium"}) |> AgentValidation.validate_agent_routing(:routing)

      assert [routing: {message, []}] = cs.errors
      assert message =~ ~s(invalid route "claude:sonnet:medium": backend "claude" accepts no effort segment; drop it and write "claude:sonnet")
      refute message =~ "valid efforts: []"
    end

    test "an effort error on a backend with efforts lists them and names the route" do
      cs = make_routing_changeset(%{3 => "codex:gpt-5.5:bogus"}) |> AgentValidation.validate_agent_routing(:routing)

      assert [routing: {message, []}] = cs.errors
      assert message =~ ~s(invalid effort "bogus" for backend "codex" in "codex:gpt-5.5:bogus"; valid efforts: [)
    end
  end

  describe "list routing values (#3960)" do
    defp routing_list_changeset(value) do
      {%{}, %{routing: :map, routing_candidates: :map}}
      |> Changeset.cast(%{routing: value}, [:routing])
      |> Changeset.update_change(:routing, &AgentValidation.normalize_agent_routing/1)
      |> AgentValidation.validate_agent_routing(:routing)
      |> AgentValidation.split_routing_candidates()
    end

    test "a list names every route a level allows; routing keeps the first, candidates keep all" do
      cs = routing_list_changeset(%{"3" => ["claude:sonnet", "codex:gpt-5.5:high"], 4 => "claude:opus"})

      assert cs.valid?
      assert Changeset.get_change(cs, :routing) == %{3 => "claude:sonnet", 4 => "claude:opus"}
      assert Changeset.get_change(cs, :routing_candidates) == %{3 => ["claude:sonnet", "codex:gpt-5.5:high"], 4 => ["claude:opus"]}
    end

    test "each list entry is validated with the single-value rules" do
      cs = routing_list_changeset(%{3 => ["claude:sonnet", "claude:sonnet:medium"]})
      assert [routing: {message, []}] = cs.errors
      assert message =~ "accepts no effort segment"

      assert [routing: {unknown, []}] = routing_list_changeset(%{3 => ["claude", "bogus"]}).errors
      assert unknown =~ "unknown or disabled backend"
    end

    test "an empty or repeating list is rejected" do
      assert [routing: {empty, []}] = routing_list_changeset(%{3 => []}).errors
      assert empty =~ "must name at least one route"

      assert [routing: {repeat, []}] = routing_list_changeset(%{3 => ["codex", "codex"]}).errors
      assert repeat =~ "must not repeat a route"
    end
  end

  describe "validate_complexity_prompts/2" do
    defp make_prompts_changeset(value) do
      {%{}, %{complexity_prompts: :map}}
      |> Changeset.cast(%{complexity_prompts: value}, [:complexity_prompts])
    end

    test "accepts valid complexity prompt map" do
      cs =
        make_prompts_changeset(%{3 => "be thorough"})
        |> AgentValidation.validate_complexity_prompts(:complexity_prompts)

      assert cs.valid?
    end

    test "rejects non-positive complexity levels" do
      cs =
        make_prompts_changeset(%{0 => "bad"})
        |> AgentValidation.validate_complexity_prompts(:complexity_prompts)

      refute cs.valid?
    end

    test "rejects non-string prompt values" do
      cs =
        make_prompts_changeset(%{3 => 123})
        |> AgentValidation.validate_complexity_prompts(:complexity_prompts)

      refute cs.valid?
    end
  end
end
