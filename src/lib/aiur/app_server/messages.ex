defmodule Aiur.AppServer.Messages do
  @moduledoc """
  Shared message envelopes and protocol constants for app-server adapters.
  """

  @version Mix.Project.config()[:version]
  @initialize_id 1

  @spec emit_message((map() -> term()), atom(), map(), map()) :: term()
  def emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  @spec default_on_message(term()) :: :ok
  def default_on_message(_message), do: :ok

  @spec normalize_tool_result(term()) :: term()
  def normalize_tool_result(%{"output" => _output} = result), do: result

  def normalize_tool_result(%{"contentItems" => [%{"text" => output} | _]} = result)
      when is_binary(output) do
    Map.put(result, "output", output)
  end

  def normalize_tool_result(result), do: result

  @spec tool_call_name(term()) :: String.t() | nil
  def tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  def tool_call_name(_params), do: nil

  @spec tool_call_arguments(term()) :: term()
  def tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  def tool_call_arguments(_params), do: %{}

  @spec issue_context(map()) :: String.t()
  def issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  @spec issue_identifier(map()) :: String.t() | nil
  def issue_identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  def issue_identifier(%{"identifier" => identifier}) when is_binary(identifier), do: identifier
  def issue_identifier(_issue), do: nil

  @spec initialize_id() :: 1
  def initialize_id, do: @initialize_id

  @spec initialize_frame() :: map()
  def initialize_frame do
    %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "aiur-orchestrator",
          "title" => "Aiur Orchestrator",
          "version" => @version
        }
      }
    }
  end

  @spec initialized_frame() :: map()
  def initialized_frame do
    %{"method" => "initialized", "params" => %{}}
  end
end
