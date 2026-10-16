defmodule Aiur.AgentTools.Dispatch do
  @moduledoc """
  Executes client-side tool calls requested by coding-agent turns.
  """

  alias Aiur.AgentTools.Blockers
  alias Aiur.AgentTools.EmitAlert
  alias Aiur.AgentTools.EmitEvent
  alias Aiur.AgentTools.{Epic, Feature}
  alias Aiur.AgentTools.LinearGraphQL
  alias Aiur.AgentTools.Response
  alias Aiur.AgentTools.ReviewThreads
  alias Aiur.AgentTools.Subscriptions
  alias Aiur.AgentTools.TicketState

  @handlers [LinearGraphQL, ReviewThreads, EmitAlert, EmitEvent, Subscriptions, Blockers, TicketState, Epic, Feature]

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    dispatch = Enum.flat_map(@handlers, fn m -> Enum.map(m.tools(), &{&1, m}) end)

    case List.keyfind(dispatch, tool, 0) do
      {^tool, module} ->
        module.execute(tool, arguments, opts)

      nil ->
        Response.failure(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    Enum.flat_map(@handlers, & &1.specs())
  end

  defdelegate reset_turn_quotas(), to: EmitEvent

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
