defmodule AiurWeb.Conversation.Access do
  @moduledoc false
  alias AiurWeb.EndpointConfig

  @spec session(Plug.Conn.t()) :: map()
  def session(conn), do: %{"conversation_loopback" => loopback?(conn.remote_ip)}

  @spec principal(map(), Phoenix.LiveView.Socket.t()) :: {:operator, :loopback | :basic_auth}
  def principal(session, socket) do
    peer = Phoenix.LiveView.get_connect_info(socket, :peer_data)
    local? = session["conversation_loopback"] == true and is_map(peer) and loopback?(peer.address)
    {:operator, if(local?, do: :loopback, else: :basic_auth)}
  end

  @spec can_reveal?(term()) :: boolean()
  def can_reveal?(principal), do: principal == {:operator, :loopback} and EndpointConfig.get(:dashboard_writable) == true

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
end
