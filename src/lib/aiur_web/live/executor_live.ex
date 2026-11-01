defmodule AiurWeb.ExecutorLive do
  @moduledoc "The attached Executor's durable conversation in a distinct dashboard frame."
  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}
  alias Aiur.Conversation.Ref
  alias AiurWeb.Conversation.Session
  alias AiurWeb.{ConversationLive, ExecutorView}

  @impl true
  def mount(_params, session, socket), do: Ref.conversation_id(Ref.executor()) |> Session.mount(session, socket) |> refresh()

  @impl true
  def handle_params(params, uri, socket), do: ConversationLive.handle_params(params, uri, socket) |> refresh()
  @impl true
  def handle_event(event, params, socket), do: ConversationLive.handle_event(event, params, socket) |> refresh()
  @impl true
  def handle_info(message, socket), do: ConversationLive.handle_info(message, socket) |> refresh()

  @impl true
  def render(assigns), do: ConversationLive.render(assigns)

  defp refresh({reply, socket}), do: {reply, assign(socket, :executor_frame, ExecutorView.present(socket.assigns))}
end
