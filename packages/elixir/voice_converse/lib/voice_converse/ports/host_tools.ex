defmodule VoiceConverse.Ports.HostTools do
  @moduledoc "Optional port for target-specific tools supplied by the host application."

  @reserved_names ~w(get_status get_details list_open_commands propose_instruction ask_agent record_summary end_conversation)

  @type tool_spec :: %{name: String.t(), description: String.t(), params: map()}

  @callback specs(target :: term()) :: {:ok, [tool_spec()]} | {:error, term()}
  @callback call(name :: String.t(), target :: term(), params :: map()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Returns whether a name belongs to a built-in voice tool."
  @spec reserved_name?(term()) :: boolean()
  def reserved_name?(name), do: name in @reserved_names
end
