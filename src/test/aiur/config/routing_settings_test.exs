defmodule Aiur.Config.RoutingSettingsTest do
  use Aiur.TestSupport
  alias Aiur.CodingAgent
  alias Aiur.Config.{RoutingValue, Schema}
  alias Aiur.Config.Schema.{AgentValidation, Codex, StringOrMap}
  alias Ecto.Changeset

  test "agent routing normalizes string levels and rejects bad levels/backends" do
    assert AgentValidation.normalize_agent_routing(nil) == %{}

    assert AgentValidation.normalize_agent_routing(%{"4" => "claude", 5 => :codex}) == %{
             4 => "claude",
             5 => "codex"
           }

    good =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{4 => "claude", 5 => "codex"}}, [:routing])
      |> AgentValidation.validate_agent_routing(:routing)

    assert good.errors == []

    bad =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{0 => "claude", 4 => "bogus"}}, [:routing])
      |> AgentValidation.validate_agent_routing(:routing)

    assert {:routing, {"complexity levels must be positive integers", []}} in bad.errors

    assert Enum.any?(bad.errors, fn
             {:routing, {msg, []}} -> msg =~ "unknown or disabled backend"
             _ -> false
           end)

    # A registered-but-not-dispatch-enabled backend is rejected by the same path
    # as an unknown one, so routing cannot reach an opt-in-only provider.
    disabled =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{4 => "deepseek"}}, [:routing])
      |> AgentValidation.validate_agent_routing(:routing)

    assert Enum.any?(disabled.errors, fn
             {:routing, {msg, []}} -> msg =~ ~s(unknown or disabled backend "deepseek")
             _ -> false
           end)

    # backend:model:effort routing values: the backend part must be known,
    # the model suffix is free-form (e.g. complexity:5 -> claude:sonnet).
    assert RoutingValue.split_routing_value("claude") == {"claude", nil}
    assert RoutingValue.split_routing_value("claude:sonnet") == {"claude", "sonnet"}
    assert RoutingValue.split_routing_value("claude:sonnet:high") == {"claude", "sonnet"}
    assert RoutingValue.split_routing_value("claude::high") == {"claude", nil}
    assert RoutingValue.split_routing_value("codex:gpt-5.5") == {"codex", "gpt-5.5"}
    assert RoutingValue.split_routing_value("codex:gpt-5.6-terra:xhigh") == {"codex", "gpt-5.6-terra"}
    assert RoutingValue.routing_effort("claude:sonnet:high") == "high"
    assert RoutingValue.routing_effort("claude:sonnet:high+remote") == "high"
    assert RoutingValue.routing_effort("claude-repl::xhigh") == "xhigh"
    assert RoutingValue.routing_effort("claude:sonnet") == nil

    with_model =
      {%{}, %{routing: :map}}
      |> Changeset.cast(
        %{
          routing: %{
            3 => "claude:sonnet:high+remote",
            4 => "claude-repl:sonnet:max",
            5 => "codex::high"
          }
        },
        [
          :routing
        ]
      )
      |> AgentValidation.validate_agent_routing(:routing)

    assert with_model.errors == []

    bad_effort =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{4 => "claude:sonnet:high", 5 => "codex:gpt-5.6-luna:minimal"}}, [
        :routing
      ])
      |> AgentValidation.validate_agent_routing(:routing)

    assert Enum.count(bad_effort.errors) == 2

    assert Enum.any?(bad_effort.errors, fn
             {:routing, {msg, []}} -> msg =~ ~s(backend "claude" accepts no effort segment; drop it and write "claude:sonnet")
             _ -> false
           end)

    assert Enum.any?(bad_effort.errors, fn
             {:routing, {msg, []}} -> msg =~ ~s(invalid effort "minimal" for backend "codex")
             _ -> false
           end)

    bad_model_backend =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{4 => "bogus:sonnet"}}, [:routing])
      |> AgentValidation.validate_agent_routing(:routing)

    assert Enum.any?(bad_model_backend.errors, fn
             {:routing, {msg, []}} -> msg =~ "unknown or disabled backend"
             _ -> false
           end)

    repl =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{4 => "claude-repl"}}, [:routing])
      |> AgentValidation.validate_agent_routing(:routing)

    assert repl.errors == []

    # `+remote` flag: stripped from backend/model, surfaced by
    # routing_remote_flag?, and only valid on a remote-capable backend.
    assert RoutingValue.split_routing_value("claude:haiku+remote") == {"claude", "haiku"}
    assert RoutingValue.split_routing_value("claude+remote") == {"claude", nil}
    assert RoutingValue.routing_remote_flag?("claude:haiku+remote")
    refute RoutingValue.routing_remote_flag?("claude:haiku")

    remote_ok =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{1 => "claude:haiku+remote"}}, [:routing])
      |> AgentValidation.validate_agent_routing(:routing)

    assert remote_ok.errors == []

    remote_bad =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{1 => "codex:gpt-5.4+remote"}}, [:routing])
      |> AgentValidation.validate_agent_routing(:routing)

    assert Enum.any?(remote_bad.errors, fn
             {:routing, {msg, []}} -> msg =~ "remote-capable backend"
             _ -> false
           end)
  end

  test "agent routing resolves backend model and effort per complexity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "codex",
      agent_routing: %{4 => "claude-repl:sonnet:max", 5 => "codex::high"}
    )

    claude_issue = %Issue{labels: ["complexity:4"]}
    codex_issue = %Issue{labels: ["complexity:5"]}

    assert CodingAgent.backend_for(claude_issue) == "claude-repl"
    assert CodingAgent.model_for(claude_issue) == "sonnet"
    assert CodingAgent.effort_for(claude_issue) == "max"

    assert CodingAgent.backend_for(codex_issue) == "codex"
    assert CodingAgent.model_for(codex_issue) == nil
    assert CodingAgent.effort_for(codex_issue) == "high"

    override_issue = %Issue{labels: ["complexity:4", "model:codex-gpt-5.6-sol"]}
    assert CodingAgent.backend_for(override_issue) == "codex"
    assert CodingAgent.model_for(override_issue) == "gpt-5.6-sol"
    assert CodingAgent.effort_for(override_issue) == nil

    # A model:<effort> override label wins over the routed effort.
    effort_label_issue = %Issue{labels: ["complexity:4", "model:xhigh"]}
    assert CodingAgent.effort_for(effort_label_issue) == "xhigh"

    # It applies even alongside a model:<backend> override that otherwise
    # suppresses routing effort.
    effort_with_backend = %Issue{labels: ["complexity:4", "model:codex", "model:high"]}
    assert CodingAgent.effort_for(effort_with_backend) == "high"
  end
end
