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
