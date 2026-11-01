defmodule Aiur.AgentRunner.McpSocketFailure do
  @moduledoc false

  alias Aiur.CodingAgent.RouteFailure

  @spec exit_if_launch_failure(term()) :: :ok | no_return()
  def exit_if_launch_failure({:error, {:turn_failed, details}}) when is_map(details),
    do: exit_if_socket_path_failure(details)

  def exit_if_launch_failure({:turn_failed, details}) when is_map(details),
    do: exit_if_socket_path_failure(details)

  def exit_if_launch_failure(_reason), do: :ok

  defp exit_if_socket_path_failure(details) do
    if RouteFailure.mcp_socket_path_error?(details),
      do: exit({:mcp_socket_launch_failed, details}),
      else: :ok
  end
end
