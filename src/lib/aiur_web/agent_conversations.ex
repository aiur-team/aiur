defmodule AiurWeb.AgentConversations do
  @moduledoc """
  On-demand agent conversations for host apps (#8154).

  A host starts a worker-like conversation without filing a ticket itself: aiur
  files one, labelled `<prefix>:todo` and `<prefix>:conversation`, so the
  conversation runs as an ordinary worker on its own branch and survives the
  host disconnecting. The host then reads and steers it through the ticket's
  thread API (`/api/v1/:ticket/thread`, `/api/v1/:ticket/messages`). Promoting it
  to an ordinary ticket is removing the `conversation` label; its history is
  that ticket's history.

  Every start notifies the Executor at once: an `executor.agent_conversation.started`
  wake and an `operator.notify.info` event for host feeds.
  """

  alias Aiur.{ExecutorEvents, OperatorNotify, Tracker}

  @max_text 20_000
  @max_logs 50_000
  @max_skills 8
  @slug ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @owner ~r/\A[A-Za-z0-9._:@-]{1,128}\z/
  @request_id ~r/\A[A-Za-z0-9._:-]{1,128}\z/

  @type error ::
          :blank_text | :text_too_long | :invalid_owner | :invalid_path | :invalid_skills | :logs_too_long | :invalid_complexity | :invalid_request_id | {:tracker, term()}

  @doc """
  Files the conversation's ticket and notifies the Executor. A repeated
  `client_request_id` returns the ticket filed by the first request.
  """
  @spec start(map(), keyword()) :: {:ok, map()} | {:error, error()}
  def start(params, opts \\ []) when is_map(params) do
    with {:ok, request} <- validate(params),
         {:ok, ticket, created?} <- file(request, opts) do
      if created?, do: announce(request, ticket, opts)
      {:ok, response(request, ticket, created?)}
    end
  end

  defp validate(params) do
    with {:ok, text} <- text(params["text"]),
         {:ok, owner} <- match(params["owner"], @owner, :invalid_owner),
         {:ok, path} <- path(params["path"]),
         {:ok, skills} <- skills(params["skills"]),
         {:ok, logs} <- logs(params["logs"]),
         {:ok, complexity} <- complexity(params["complexity"]),
         {:ok, id} <- request_id(params["client_request_id"]) do
      {:ok, %{text: text, owner: owner, path: path, skills: skills, logs: logs, complexity: complexity, id: id, title: title(params["title"], text)}}
    end
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :blank_text}
      text when byte_size(text) > @max_text -> {:error, :text_too_long}
      text -> {:ok, text}
    end
  end

  defp text(_value), do: {:error, :blank_text}

  defp match(value, regex, error) when is_binary(value), do: if(Regex.match?(regex, value), do: {:ok, value}, else: {:error, error})
  defp match(_value, _regex, error), do: {:error, error}

  defp path(nil), do: {:ok, nil}
  defp path(""), do: {:ok, nil}

  defp path(value) when is_binary(value) do
    parts = Path.split(value)
    if Path.type(value) == :relative and ".." not in parts and byte_size(value) <= 512, do: {:ok, Path.join(parts)}, else: {:error, :invalid_path}
  end

  defp path(_value), do: {:error, :invalid_path}

  defp skills(nil), do: {:ok, []}

  defp skills(list) when is_list(list) and length(list) <= @max_skills do
    if Enum.all?(list, &(is_binary(&1) and Regex.match?(@slug, &1))), do: {:ok, Enum.uniq(list)}, else: {:error, :invalid_skills}
  end

  defp skills(_value), do: {:error, :invalid_skills}

  defp logs(nil), do: {:ok, nil}
  defp logs(value) when is_binary(value) and byte_size(value) <= @max_logs, do: {:ok, value}
  defp logs(value) when is_binary(value), do: {:error, :logs_too_long}
  defp logs(_value), do: {:error, :logs_too_long}

  defp complexity(nil), do: {:ok, nil}
  defp complexity(value) when value in 1..5, do: {:ok, value}
  defp complexity(_value), do: {:error, :invalid_complexity}

  defp request_id(nil), do: {:ok, "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}
  defp request_id(value), do: match(value, @request_id, :invalid_request_id)

  defp title(value, _text) when is_binary(value) and value != "", do: String.slice(String.trim(value), 0, 120)
  defp title(_value, text), do: "Conversation: " <> (text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 100))

  defp file(request, opts) do
    marker = marker(request.id)

    case Keyword.get(opts, :find_issue, &Tracker.find_issue/2).(marker, caller: "agent_conversation_find") do
      {:ok, %{} = existing} ->
        {:ok, ticket(existing), false}

      {:ok, nil} ->
        attrs = %{title: request.title, body: body(request, marker), labels: labels(request, opts)}

        case Keyword.get(opts, :create_issue, &Tracker.create_issue/2).(attrs, caller: "agent_conversation_create") do
          {:ok, created} -> {:ok, ticket(created), true}
          {:error, reason} -> {:error, {:tracker, reason}}
        end

      {:error, reason} ->
        {:error, {:tracker, reason}}
    end
  end

  defp labels(request, opts) do
    prefix = Keyword.get_lazy(opts, :label_prefix, &label_prefix/0)
    complexity = if request.complexity, do: ["complexity:#{request.complexity}"], else: []
    ["#{prefix}:todo", "#{prefix}:conversation"] ++ complexity
  end

  defp label_prefix do
    case Aiur.Config.settings() do
      {:ok, %{tracker: %{github: %{label_prefix: prefix}}}} when is_binary(prefix) -> prefix
      _ -> "agent"
    end
  end

  defp marker(id), do: "<!-- aiur:agent-conversation:#{id} -->"

  defp body(request, marker) do
    [
      marker,
      "On-demand agent conversation started by `#{request.owner}` from a host app.",
      if(request.path, do: "Scope: work under `#{request.path}`."),
      if(request.skills != [], do: "Skills to use: " <> Enum.map_join(request.skills, ", ", &"`#{&1}`") <> "."),
      "The host reads this ticket's thread and may send more messages, images and steering while you work.",
      "## Request\n\n" <> request.text,
      if(request.logs, do: "## Logs\n\n```text\n" <> String.replace(request.logs, "```", "` ` `") <> "\n```")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp ticket(issue) do
    number = Map.get(issue, "number") || Map.get(issue, :number) || Map.get(issue, :identifier)
    %{ticket: to_string(number), url: Map.get(issue, "url") || Map.get(issue, :url)}
  end

  defp announce(request, ticket, opts) do
    text = "Agent conversation ##{ticket.ticket} started by #{request.owner}: #{request.title}"
    _ = Keyword.get(opts, :notify, &OperatorNotify.notify/3).("info", text, ticket: ticket.ticket, url: ticket.url)

    payload = %{ticket: ticket.ticket, url: ticket.url, owner: request.owner, path: request.path, title: request.title, conversation_id: request.id}
    _ = Keyword.get(opts, :publish, &ExecutorEvents.publish/3).("executor.agent_conversation.started", payload, source: :internal)
    _ = Keyword.get(opts, :refresh, &refresh/0).()
    :ok
  end

  defp refresh do
    Aiur.Orchestrator.request_refresh(Aiur.Orchestrator.server())
  rescue
    _error -> :unavailable
  catch
    :exit, _reason -> :unavailable
  end

  defp response(request, ticket, created?) do
    %{
      conversation_id: request.id,
      ticket: ticket.ticket,
      url: ticket.url,
      created: created?,
      thread: "/api/v1/#{ticket.ticket}/thread",
      messages: "/api/v1/#{ticket.ticket}/messages"
    }
  end
end
