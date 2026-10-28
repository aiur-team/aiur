defmodule Aiur.Conversation.History do
  @moduledoc """
  Read-only access to live conversations, workspace transcripts and observed anchors.

  Keeps the existing stores' results and failures unchanged. Live conversation
  writes remain owned by the agent runner.
  """

  alias Aiur.AgentEventFeed
  alias Aiur.AgentLog
  alias Aiur.AgentLog.PageReader
  alias Aiur.Conversation.{Anchors, HistoryAnchors, HistoryPage, HistoryReader, Ref}
  alias Aiur.LiveConversation
  alias Aiur.SecretRedactor

  @type page :: %{
          entries: [map()],
          sessions: [Aiur.Conversation.Session.t()],
          prev_cursor: pos_integer() | nil,
          next_cursor: non_neg_integer() | nil,
          head_pos: non_neg_integer(),
          complete_from_start: boolean(),
          observed_at: DateTime.t()
        }

  @doc "Pages durable entries by position. A principal is required; only loopback may reveal secrets."
  @spec list_entries(Ref.t() | String.t(), keyword()) :: {:ok, page()} | {:error, atom()}
  def list_entries(ref, opts) do
    principal!(opts)

    with {:ok, cursor, limit} <- HistoryPage.options(opts),
         {:ok, snapshot} <- HistoryReader.snapshot(ref),
         {:ok, page} <- HistoryPage.read(snapshot, cursor, limit, opts) do
      {:ok, %{page | entries: Enum.map(page.entries, &mask_for(&1, opts))}}
    end
  end

  @spec list_sessions(Ref.t() | String.t()) :: {:ok, [Aiur.Conversation.Session.t()]} | {:error, atom()}
  def list_sessions(ref) do
    with {:ok, snapshot} <- HistoryReader.snapshot(ref), do: HistoryReader.sessions(snapshot)
  end

  @spec list_anchors(Ref.t() | String.t(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def list_anchors(ref, opts \\ []) do
    with {:ok, snapshot} <- HistoryReader.snapshot(ref), do: HistoryAnchors.read(snapshot, opts)
  end

  @doc "Subscribe first, catch up, then discard live entries at or below the returned head. Live entries are raw."
  @spec subscribe(Ref.t() | String.t()) :: :ok | {:error, atom()}
  def subscribe(ref) do
    with {:ok, snapshot} <- HistoryReader.snapshot(ref) do
      pubsub = Application.get_env(:aiur, :conversation_journal, []) |> Keyword.get(:pubsub, Aiur.PubSub)
      Phoenix.PubSub.subscribe(pubsub, "conversation:" <> snapshot.id)
    end
  end

  @doc "Catch up at most 5,000 positions to a fixed head in one pass. Page with after: when the span is too large."
  @spec catch_up(Ref.t() | String.t(), non_neg_integer(), keyword()) :: {:ok, [map()], non_neg_integer()} | {:error, :catch_up_too_far, non_neg_integer()} | {:error, atom()}
  def catch_up(ref, last_pos, opts \\ []) do
    principal!(opts)

    with {:ok, _, _} <- HistoryPage.options(after: last_pos),
         {:ok, snapshot} <- HistoryReader.snapshot(ref) do
      catch_entries(snapshot, last_pos, opts)
    end
  end

  defp catch_entries(%{head: %{"last_pos" => head}}, last_pos, _opts) when head - last_pos > 5_000,
    do: {:error, :catch_up_too_far, head}

  defp catch_entries(snapshot, last_pos, opts) do
    snapshot
    |> HistoryReader.entries(last_pos + 1, snapshot.head["last_pos"], :forward)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, entry}, {:ok, entries} -> {:cont, {:ok, [mask_for(entry, opts) | entries]}}
      _, _ -> {:halt, {:error, :unavailable}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries), snapshot.head["last_pos"]}
      error -> error
    end
  end

  @doc "Applies the same body/output masking to a live entry as to a page. Accepts a principal or read options."
  @spec mask_for(map(), keyword() | :internal | {:device, String.t()} | {:operator, atom()}) :: map()
  def mask_for(entry, opts) when is_list(opts) do
    principal = principal!(opts)
    entry = if is_struct(entry), do: Map.from_struct(entry), else: entry

    if principal == :internal or (principal == {:operator, :loopback} and Keyword.get(opts, :reveal) == true) do
      entry
    else
      masked = Enum.reduce([:body, :output], entry, &mask_text/2)
      if masked != entry, do: Map.put(masked, :redacted, true), else: masked
    end
  end

  def mask_for(entry, principal), do: mask_for(entry, principal: principal)

  defp mask_text(field, entry) do
    key = if Map.has_key?(entry, field), do: field, else: Atom.to_string(field)

    case Map.get(entry, key) do
      text when is_binary(text) -> Map.put(entry, key, text |> SecretRedactor.redact() |> SecretRedactor.redact_urls())
      _ -> entry
    end
  end

  defp principal!(opts) do
    case Keyword.fetch(opts, :principal) do
      {:ok, :internal} -> :internal
      {:ok, {:operator, method} = principal} when method in [:loopback, :basic_auth] -> principal
      {:ok, {:device, id} = principal} when is_binary(id) -> principal
      _ -> raise ArgumentError, "a valid conversation principal is required"
    end
  end

  @spec log_tail(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def log_tail(path, opts \\ []), do: PageReader.tail(path, opts)

  @spec log_before(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def log_before(path, cursor, opts \\ []), do: PageReader.before(path, cursor, opts)

  @spec log_since(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def log_since(path, cursor, opts \\ []), do: PageReader.since(path, cursor, opts)

  @spec structured_entry(String.t()) :: map() | nil
  def structured_entry(line), do: AgentLog.structured_entry(line)

  @spec workspace_paged_tail(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def workspace_paged_tail(workspace, opts \\ []), do: log_tail(AgentLog.workspace_structured_log_path(workspace), opts)

  @spec workspace_paged_before(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def workspace_paged_before(workspace, cursor, opts \\ []), do: log_before(AgentLog.workspace_structured_log_path(workspace), cursor, opts)

  @spec workspace_paged_since(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def workspace_paged_since(workspace, cursor, opts \\ []), do: log_since(AgentLog.workspace_structured_log_path(workspace), cursor, opts)

  defdelegate live_resolve(handle), to: LiveConversation, as: :resolve
  defdelegate live_subscribe(handle), to: LiveConversation, as: :subscribe_handle
  defdelegate live_unsubscribe(handle), to: LiveConversation, as: :unsubscribe_handle
  defdelegate transcript(identifier, params), to: AgentEventFeed, as: :list
  defdelegate bus_events(identifier), to: AgentEventFeed
  defdelegate bus_events(identifier, opts), to: AgentEventFeed
  defdelegate workspace_log(workspace), to: AgentLog, as: :read_workspace
  defdelegate read_log(path), to: AgentLog, as: :read
  defdelegate parse_log(content), to: AgentLog, as: :parse
  defdelegate workspace_log_path(workspace), to: AgentLog
  defdelegate anchor(events, entries), to: Anchors, as: :at_or_before
  defdelegate load_anchors(events, entries), to: Anchors, as: :with_origin
end
