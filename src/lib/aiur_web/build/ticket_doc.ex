defmodule AiurWeb.Build.TicketDoc do
  @moduledoc "Issue body presentation and subscriptions for the build home modal."
  import Phoenix.Component, only: [assign: 2]
  alias Aiur.BuildOrder.TicketDetail.{Failure, Snapshot, State}
  alias Aiur.BuildOrder.TicketDetailCoordinator
  alias Aiur.TrackerIdentity
  alias AiurWeb.Build.{DataSource, Payload, Read, TicketDocIdentity}
  alias AiurWeb.{EndpointConfig, Markdown}

  @failures ~w(auth permission rate_limited timeout transport not_found schema validation provider_identity_mismatch nonfetchable_repository configuration capacity evicted)

  @spec init(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def init(socket, connected) do
    if connected, do: Phoenix.PubSub.subscribe(Aiur.PubSub, TicketDetailCoordinator.reset_topic())
    assign(socket, doc_id: nil, doc_identity: nil)
  end

  @spec present(String.t(), term()) :: map()
  def present(id, input) do
    Map.merge(%{v: 1, kind: "doc", id: id, body_html: nil, author: nil, created: nil, observed_at: nil, reason: nil, retry_after: nil}, content(input))
  end

  defp content(:no_identity), do: %{state: "identity_unknown", reason: "identity_unknown"}
  defp content({:ok, %State{health: :unavailable, detail: nil, failure: nil}}), do: %{state: "loading"}
  defp content({:ok, %State{health: :unavailable, failure: failure}}), do: failure(failure)

  defp content({:ok, %State{health: health, detail: %Snapshot{} = detail, failure: failure}}) when health in [:healthy, :stale] do
    %{
      state: if(health == :stale, do: "stale", else: if(is_nil(detail.description), do: "empty", else: "available")),
      body_html: if(is_binary(detail.description), do: detail.description |> Markdown.render() |> Phoenix.HTML.safe_to_string()),
      author: detail.author_login,
      created: milliseconds(detail.created_at),
      observed_at: milliseconds(detail.observed_at),
      reason: if(health == :stale, do: if(is_nil(failure), do: "not_fresh", else: reason(failure)), else: nil),
      retry_after: retry_after(failure)
    }
  end

  defp content({:error, failure}), do: failure(failure)
  defp content(_input), do: failure(nil)
  defp failure(failure), do: %{state: "unavailable", reason: reason(failure), retry_after: retry_after(failure)}
  defp reason(%Failure{kind: kind}) when is_atom(kind), do: if(to_string(kind) in @failures, do: to_string(kind), else: "unknown")
  defp reason(_failure), do: "unknown"
  defp retry_after(%Failure{retry_after: seconds}) when is_integer(seconds) and seconds > 0, do: min(seconds, 60)
  defp retry_after(_failure), do: nil
  defp milliseconds(%DateTime{} = date), do: DateTime.to_unix(date, :millisecond)
  defp milliseconds(_date), do: nil

  @spec open(Phoenix.LiveView.Socket.t(), map()) :: {:reply, map(), Phoenix.LiveView.Socket.t()}
  def open(socket, %{"id" => id}) when is_binary(id) do
    if Regex.match?(~r/\A[1-9][0-9]{0,9}\z/, id) do
      socket = close(socket)
      result = safely(fn -> DataSource.call(socket.assigns.build_source, :ticket_doc_identity, [id, Read.source_opts(socket)]) end)
      open_identity(socket, id, result)
    else
      {:reply, Payload.error(:invalid_params), socket}
    end
  end

  def open(socket, _params), do: {:reply, Payload.error(:invalid_params), socket}

  defp open_identity(socket, id, {:ok, %TrackerIdentity{} = identity}) do
    if TrackerIdentity.joinable?(identity) and identity.identifier == id do
      result =
        with :ok <- call(:ticket_detail_subscribe_fun, &subscribe/1, identity),
             do: request(identity)

      socket = assign(socket, doc_id: id, doc_identity: identity)
      {:reply, Payload.scrub(present(id, validate_identity(result, identity))), socket}
    else
      {:reply, Payload.scrub(present(id, {:error, :invalid_identity})), socket}
    end
  end

  defp open_identity(socket, id, result), do: {:reply, Payload.scrub(present(id, result)), socket}

  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket) do
    if identity = socket.assigns[:doc_identity], do: call(:ticket_detail_unsubscribe_fun, &unsubscribe/1, identity)
    assign(socket, doc_id: nil, doc_identity: nil)
  end

  @spec update(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def update(%{assigns: %{doc_identity: %TrackerIdentity{} = identity}} = socket, {:ticket_detail_updated, %State{} = state}) do
    if same_identity?(identity, state.identity), do: push(socket, {:ok, state}), else: socket
  end

  def update(%{assigns: %{doc_identity: %TrackerIdentity{} = identity}} = socket, {:ticket_detail_coordinator_reset, _epoch}),
    do: push(socket, validate_identity(request(identity), identity))

  def update(socket, _message), do: socket

  @spec live_identity(String.t(), keyword()) :: {:ok, TrackerIdentity.t()} | :no_identity | {:error, term()}
  defdelegate live_identity(id, opts), to: TicketDocIdentity

  defp push(socket, result), do: Phoenix.LiveView.push_event(socket, "build-ticket-doc", Payload.scrub(present(socket.assigns.doc_id, result)))
  defp request(identity), do: call(:ticket_detail_request_fun, &TicketDetailCoordinator.request/1, identity)
  defp subscribe(identity), do: Phoenix.PubSub.subscribe(Aiur.PubSub, TicketDetailCoordinator.topic(identity))
  defp unsubscribe(identity), do: Phoenix.PubSub.unsubscribe(Aiur.PubSub, TicketDetailCoordinator.topic(identity))
  defp call(key, default, identity), do: safely(fn -> (EndpointConfig.get(key) || default).(identity) end)

  defp validate_identity({:ok, %State{} = state} = result, identity),
    do: if(same_identity?(state.identity, identity), do: result, else: {:error, :identity_mismatch})

  defp validate_identity(result, _identity), do: result
  defp same_identity?(left, right), do: not is_nil(TrackerIdentity.github_key(left)) and TrackerIdentity.github_key(left) == TrackerIdentity.github_key(right)

  defp safely(fun) do
    fun.()
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end
end
