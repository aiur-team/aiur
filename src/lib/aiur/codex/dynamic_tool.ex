defmodule Aiur.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias Aiur.Codex.DynamicTool.Blockers
  alias Aiur.Codex.DynamicTool.EmitAlert
  alias Aiur.Codex.DynamicTool.EmitEvent
  alias Aiur.Codex.DynamicTool.LinearGraphQL
  alias Aiur.Codex.DynamicTool.Response
  alias Aiur.Codex.DynamicTool.ReviewThreads
  alias Aiur.Codex.DynamicTool.ReportUntestable
  alias Aiur.Codex.DynamicTool.Subscriptions

  @handlers [LinearGraphQL, ReviewThreads, EmitAlert, EmitEvent, ReportUntestable, Subscriptions, Blockers]

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
