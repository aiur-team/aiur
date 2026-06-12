defmodule Aiur.Opencode.TurnMarkers do
  @moduledoc """
  Posting and parsing of `__aiur_turn__:<id>` markers — the synthetic user
  messages that make opencode open a chat-completion request the bridge can
  stream an agent turn through.

  One marker opens one stream segment. The initial marker for a turn carries
  the bare parent id (`t<base36>`) and fans out to every attached writer;
  continuation markers carry `<parent>-s<N>` and go to ONLY the writer whose
  segment stream requested them — fanning continuations to all writers would
  multiply concurrent segment streams combinatorially per boundary.

  Parent ids never contain `-` (they are `"t" <> base36`), so stripping a
  trailing `-s<N>` is unambiguous. The parent id is the single source of
  truth: ActiveTurns entries and `:aiur_turn_done` broadcasts are keyed by it
  alone — segment ids are never registered.
  """

  require Logger

  alias Aiur.Opencode.{ApiClient, Protocol}

  @marker_prefix "__aiur_turn__:"

  @type writer :: %{session_id: String.t(), base_url: String.t()}
  @type post_fn :: (String.t(), String.t(), map() -> {:ok, term()} | {:error, term()})

  @doc "The marker text posted for a turn or segment id."
  @spec marker_text(String.t()) :: String.t()
  def marker_text(turn_id) when is_binary(turn_id), do: @marker_prefix <> turn_id

  @doc """
  Split a marker-captured id into `{parent_turn_id, segment_number}`. A bare
  parent id is segment 0.
  """
  @spec parse_turn_id(String.t()) :: {String.t(), non_neg_integer()}
  def parse_turn_id(id) when is_binary(id) do
    case Regex.run(~r/\A(.+)-s(\d+)\z/, id) do
      [_, parent, seg] -> {parent, String.to_integer(seg)}
      _ -> {id, 0}
    end
  end

  @doc "The marker id for segment `seg` of `parent_turn_id` (seg >= 1)."
  @spec continuation_id(String.t(), pos_integer()) :: String.t()
  def continuation_id(parent_turn_id, seg) when is_binary(parent_turn_id) and is_integer(seg) and seg >= 1 do
    "#{parent_turn_id}-s#{seg}"
  end

  @doc """
  Fire the turn-opening marker to every attached opencode-serve
  asynchronously. Returns `:ok` immediately so the calling agent turn is not
  blocked on the round-trip.

  opencode's `POST /session/X/message` is synchronous from its caller's
  perspective — it holds the request open until the LLM (our bridge)
  finishes responding, which for an active turn can be minutes. A naive
  synchronous fan-out blocked the next turn from even starting for ~30s per
  attached server (Req's `receive_timeout`), so chat panes sat empty for
  ~90s after dispatch with 3 slots.

  Fire-and-forget is safe because the marker post is purely a trigger: once
  opencode receives the synthetic user message, it opens its chat-completion
  request to our bridge endpoint, and the bridge subscribes to `AgentPubSub`
  directly — the caller never needs the post's return value.

  The `post_fn` argument is injectable for testing; in production it
  defaults to `Aiur.Opencode.ApiClient.post_message/3`.
  """
  @spec post_all(String.t(), String.t(), [writer()], post_fn()) :: :ok
  def post_all(identifier, aiur_turn_id, writers, post_fn \\ &ApiClient.post_message/3)
      when is_binary(identifier) and is_binary(aiur_turn_id) and is_list(writers) and
             is_function(post_fn, 3) do
    payload = marker_payload(aiur_turn_id)

    for %{session_id: session_id, base_url: base_url} <- writers do
      Task.start(fn -> post_one(post_fn, base_url, session_id, payload, identifier) end)
    end

    :ok
  end

  @doc """
  Post the continuation marker for the NEXT segment of a turn to the single
  writer whose stream is closing. Synchronous-intent but still fired in a
  Task: the bridge must post-then-close without waiting on opencode's
  long-held POST. One retry on failure; a second failure is logged and the
  rest of the turn degrades to SQL-only rendering (the turn-done close
  machinery still fires).
  """
  @spec post_continuation(String.t(), String.t(), pos_integer(), writer(), post_fn()) :: :ok
  def post_continuation(identifier, parent_turn_id, seg, writer, post_fn \\ &ApiClient.post_message/3)
      when is_binary(identifier) and is_binary(parent_turn_id) and is_integer(seg) and seg >= 1 and
             is_function(post_fn, 3) do
    %{session_id: session_id, base_url: base_url} = writer
    payload = parent_turn_id |> continuation_id(seg) |> marker_payload()

    Task.start(fn ->
      case post_one(post_fn, base_url, session_id, payload, identifier) do
        :ok ->
          :ok

        :error ->
          Logger.warning("aiur_turn_marker continuation_retry identifier=#{identifier} parent=#{parent_turn_id} seg=#{seg}")

          post_one(post_fn, base_url, session_id, payload, identifier)
      end
    end)

    :ok
  end

  defp marker_payload(turn_id) do
    %{parts: [Protocol.text_part_data(marker_text(turn_id), synthetic: true)]}
  end

  defp post_one(post_fn, base_url, session_id, payload, identifier) do
    case post_fn.(base_url, session_id, payload) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.debug("aiur_turn_marker post_failed identifier=#{identifier} base_url=#{base_url} reason=#{inspect(reason)}")

        :error
    end
  end
end
