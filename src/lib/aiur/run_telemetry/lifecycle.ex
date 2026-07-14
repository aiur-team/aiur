defmodule Aiur.RunTelemetry.Lifecycle do
  @moduledoc """
  Sanitized lifecycle boundaries for debug run telemetry.

  Runtime owners emit only identifiers, phase outcomes, and coarse reason or
  command classes. Prompts, command text, command output, and comment bodies
  are deliberately excluded from the record contract.
  """

  alias Aiur.LogFile
  alias Aiur.Orchestrator.CommentWake
  alias Aiur.Protocol.MapAccess
  alias Aiur.RunTelemetry

  @events ~w(
    dispatch prewarm workspace_setup agent_spinup implement build_test
    pr_opened pr_merged review_pause comment_received rework_start
    agent_pause agent_resume
  )
  @boundaries ~w(start end point)
  @metadata_fields [
    :outcome,
    :cause,
    :operation_id,
    :command_class,
    :duration_status,
    :source,
    :source_id,
    :actor,
    :pr_number,
    :comment_id,
    :review_thread_id,
    :author_trusted,
    :source_timestamp,
    :worker_host,
    :backend,
    :prewarm_outcome,
    :reason_class,
    :turn_number,
    :remote,
    :retry_attempt
  ]

  @doc "Creates an opaque identity for one dispatched worker attempt."
  @spec new_attempt_id(String.t()) :: String.t()
  def new_attempt_id(ticket) when is_binary(ticket) do
    suffix = 10 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{ticket}:#{suffix}"
  end

  @doc false
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) when is_list(opts) do
    Keyword.has_key?(opts, :recorder) or lifecycle_recorder_override?() or
      LogFile.debug_enabled?()
  end

  @doc "Records one lifecycle start, end, or point without propagating failures."
  @spec record(String.t(), String.t() | nil, atom() | String.t(), atom() | String.t(), map(), keyword()) :: :ok
  def record(ticket, attempt_id, event, boundary, metadata \\ %{}, opts \\ [])

  def record(ticket, attempt_id, event, boundary, metadata, opts)
      when is_binary(ticket) and is_map(metadata) and is_list(opts) do
    event = normalize_name(event)
    boundary = normalize_name(boundary)

    if enabled?(opts) and event in @events and boundary in @boundaries do
      attributes = attributes(ticket, attempt_id, event, boundary, metadata)

      recorder =
        Keyword.get(opts, :recorder) ||
          Application.get_env(:aiur, :run_telemetry_lifecycle_recorder, &RunTelemetry.record/3)

      recorder.(:lifecycle, attributes, Keyword.take(opts, [:timestamp]))
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
    _kind, _reason -> :ok
  end

  def record(_ticket, _attempt_id, _event, _boundary, _metadata, _opts), do: :ok

  @doc false
  @spec reason_class(term()) :: String.t()
  def reason_class(reason)
  def reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)

  def reason_class(%{__struct__: module}) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  def reason_class({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  def reason_class({tag, _detail, _more}) when is_atom(tag), do: Atom.to_string(tag)
  def reason_class(status) when is_integer(status), do: "status_#{status}"
  def reason_class(_reason), do: "unknown"

  @doc "Observes backend command lifecycle notifications and emits build/test boundaries."
  @spec observe_backend_message(String.t(), String.t() | nil, String.t(), map(), keyword()) :: :ok
  def observe_backend_message(ticket, attempt_id, backend, message, opts \\ [])

  def observe_backend_message(ticket, attempt_id, backend, message, opts)
      when is_binary(ticket) and is_binary(backend) and is_map(message) and is_list(opts) do
    if enabled?(opts) do
      tracker = Keyword.get(opts, :tracker, self())
      timestamp = MapAccess.message_timestamp(message)

      case backend_operation(backend, message) do
        {:start, operation_id, command} ->
          observe_operation_start(ticket, attempt_id, tracker, operation_id, command, timestamp, opts)

        {:complete, operation_id, command, outcome} ->
          observe_operation_complete(ticket, attempt_id, tracker, operation_id, command, outcome, timestamp, opts)

        :skip ->
          :ok
      end
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
    _kind, _reason -> :ok
  end

  def observe_backend_message(_ticket, _attempt_id, _backend, _message, _opts), do: :ok

  @doc "Converts a trusted GitHub exchange event into a body-free lifecycle anchor."
  @spec external_anchor(map()) :: {:ok, map(), term()} | :skip
  def external_anchor(event) when is_map(event) do
    topic = value(event, :topic)
    source = value(event, :source)

    with true <- source in [:github, "github"],
         {:ok, ticket, kind} <- external_topic(topic),
         true <- eligible_external_event?(kind, event) do
      timestamp = external_timestamp(kind, event)
      metadata = external_metadata(kind, event, timestamp)
      {:ok, attributes(ticket, nil, external_event(kind), "point", metadata), timestamp}
    else
      _other -> :skip
    end
  rescue
    _error -> :skip
  end

  def external_anchor(_event), do: :skip

  defp attributes(ticket, attempt_id, event, boundary, metadata) do
    metadata = sanitized_metadata(metadata)

    identity = {
      ticket,
      attempt_id,
      event,
      boundary,
      Map.get(metadata, :operation_id),
      Map.get(metadata, :source_id)
    }

    metadata
    |> Map.merge(%{
      ticket: ticket,
      attempt_id: normalize_optional_string(attempt_id),
      event: event,
      boundary: boundary,
      event_key: event_key(identity)
    })
  end

  defp sanitized_metadata(metadata) do
    metadata
    |> Enum.flat_map(fn {key, value} ->
      atom_key = metadata_key(key)

      if atom_key in @metadata_fields and not is_nil(value) do
        [{atom_key, normalize_metadata_value(value)}]
      else
        []
      end
    end)
    |> Map.new()
  end

  defp metadata_key(key) when is_atom(key), do: key

  defp metadata_key(key) when is_binary(key) do
    Enum.find(@metadata_fields, &(Atom.to_string(&1) == key))
  end

  defp metadata_key(_key), do: nil

  defp normalize_metadata_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_metadata_value(value) when is_boolean(value), do: value
  defp normalize_metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_metadata_value(value) when is_binary(value) or is_number(value), do: value
  defp normalize_metadata_value(_value), do: "unknown"

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: value
  defp normalize_optional_string(value), do: to_string(value)

  defp normalize_name(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_name(value) when is_binary(value), do: value
  defp normalize_name(_value), do: ""

  defp lifecycle_recorder_override? do
    is_function(Application.get_env(:aiur, :run_telemetry_lifecycle_recorder), 3)
  end

  defp event_key(identity) do
    identity
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 22)
  end

  defp observe_operation_start(ticket, attempt_id, tracker, operation_id, command, timestamp, opts) do
    case command_class(command) do
      nil ->
        :ok

      command_class ->
        Process.put(operation_key(tracker, attempt_id, operation_id), command_class)

        record(
          ticket,
          attempt_id,
          :build_test,
          :start,
          %{operation_id: operation_id, command_class: command_class},
          Keyword.put(opts, :timestamp, timestamp)
        )
    end
  end

  defp observe_operation_complete(ticket, attempt_id, tracker, operation_id, command, outcome, timestamp, opts) do
    previous_class = Process.delete(operation_key(tracker, attempt_id, operation_id))
    command_class = previous_class || command_class(command)

    if command_class do
      boundary = if previous_class, do: :end, else: :point

      metadata = %{
        operation_id: operation_id,
        command_class: command_class,
        outcome: outcome,
        duration_status: if(boundary == :point, do: :unavailable, else: :measured)
      }

      record(ticket, attempt_id, :build_test, boundary, metadata, Keyword.put(opts, :timestamp, timestamp))
    end
  end

  defp operation_key(tracker, attempt_id, operation_id),
    do: {__MODULE__, :operation, tracker, attempt_id, operation_id}

  defp backend_operation("codex", message) do
    method = MapAccess.notification_method(message)
    item = MapAccess.notification_item(message)

    with item when is_map(item) <- item,
         "commandExecution" <- value(item, :type),
         operation_id when not is_nil(operation_id) <- operation_id(item) do
      command = command_from_codex(item)

      case method do
        "item/started" -> {:start, operation_id, command}
        "item/completed" -> {:complete, operation_id, command, codex_outcome(item)}
        _other -> :skip
      end
    else
      _other -> :skip
    end
  end

  defp backend_operation("claude", message), do: claude_operation(message)
  defp backend_operation("claude-repl", message), do: claude_operation(message)
  defp backend_operation(_backend, _message), do: :skip

  defp claude_operation(message) do
    with "item/created" <- MapAccess.notification_method(message),
         item when is_map(item) <- MapAccess.notification_item(message) do
      case value(item, :type) do
        "tool_call" ->
          claude_tool_call(item)

        "tool_result" ->
          claude_tool_result(item)

        _other ->
          :skip
      end
    else
      _other -> :skip
    end
  end

  defp claude_tool_call(item) do
    with "Bash" <- value(item, :name),
         operation_id when not is_nil(operation_id) <- operation_id(item) do
      input = value(item, :input) || %{}
      {:start, operation_id, value(input, :command)}
    else
      _other -> :skip
    end
  end

  defp claude_tool_result(item) do
    operation_id =
      value(item, :tool_use_id) || value(item, :tool_call_id) || value(item, :call_id)

    if operation_id do
      {:complete, to_string(operation_id), nil, claude_outcome(item)}
    else
      :skip
    end
  end

  defp operation_id(item) do
    case value(item, :id) || value(item, :item_id) do
      nil -> nil
      id -> to_string(id)
    end
  end

  defp command_from_codex(item) do
    case value(item, :commandActions) do
      [first | _rest] when is_map(first) -> value(first, :command) || value(item, :command)
      _other -> value(item, :command)
    end
  end

  defp codex_outcome(item) do
    case value(item, :exitCode) do
      0 -> :success
      code when is_integer(code) -> :failed
      _other -> :unknown
    end
  end

  defp claude_outcome(item) do
    case value(item, :is_error) do
      true -> :failed
      false -> :success
      _other -> :unknown
    end
  end

  defp command_class(command) when is_binary(command) do
    command = String.downcase(command)

    cond do
      contains_any?(command, [
        "mix test",
        "make ci",
        "npm test",
        "npm run test",
        "pnpm test",
        "yarn test",
        "pytest",
        "rspec",
        "cargo test",
        "go test",
        "swift test",
        "gradle test",
        "mvn test"
      ]) ->
        :test

      contains_any?(command, [
        "mix compile",
        "mix deps.compile",
        "npm run build",
        "pnpm build",
        "yarn build",
        "cargo build",
        "cargo check",
        "go build",
        "make build",
        "aiurdev build",
        "xcodebuild"
      ]) ->
        :build

      true ->
        nil
    end
  end

  defp command_class(_command), do: nil
  defp contains_any?(text, needles), do: Enum.any?(needles, &String.contains?(text, &1))

  defp external_topic(topic) when is_binary(topic) do
    case Regex.run(~r/^ticket\.([^.]+)\.(pr\.opened|pr\.merged|issue\.commented|pr\.review_comment)$/, topic) do
      [_all, ticket, kind] -> {:ok, ticket, kind}
      _other -> :error
    end
  end

  defp external_topic(_topic), do: :error

  defp eligible_external_event?(kind, event)
       when kind in ["issue.commented", "pr.review_comment"] do
    CommentWake.actionable_trusted_comment_event?(event)
  end

  defp eligible_external_event?(_kind, _event), do: true

  defp external_event("pr.opened"), do: "pr_opened"
  defp external_event("pr.merged"), do: "pr_merged"
  defp external_event(_comment), do: "comment_received"

  defp external_metadata(kind, event, timestamp) do
    pr = value(event, :pr) || %{}
    comment = value(event, :comment) || %{}
    pr_number = value(pr, :number)
    comment_id = value(comment, :id)
    review_thread_id = value(comment, :review_thread_id)

    source_id =
      cond do
        not is_nil(comment_id) -> "comment:#{comment_id}"
        not is_nil(review_thread_id) -> "review_thread:#{review_thread_id}"
        not is_nil(pr_number) -> "pr:#{pr_number}:#{kind}"
        true -> "exchange:#{value(event, :id)}"
      end

    %{
      source: :github,
      source_id: source_id,
      source_timestamp: timestamp,
      actor: external_actor(event, pr, comment),
      pr_number: pr_number,
      comment_id: comment_id,
      review_thread_id: review_thread_id,
      author_trusted: value(event, :author_trusted?) == true
    }
  end

  defp external_actor(event, pr, comment) do
    comment_actor = comment |> value(:user) |> value(:login)
    pr_actor = pr |> value(:user) |> value(:login)
    value(event, :author) || comment_actor || pr_actor
  end

  defp external_timestamp(kind, event) do
    case kind |> external_timestamp_candidates(event) |> Enum.find(& &1) do
      nil -> DateTime.utc_now()
      timestamp -> timestamp
    end
  end

  defp external_timestamp_candidates("pr.opened", event) do
    [value(value(event, :pr), :created_at), value(event, :timestamp)]
  end

  defp external_timestamp_candidates("pr.merged", event) do
    pr = value(event, :pr)
    [value(pr, :merged_at), value(pr, :closed_at), value(event, :timestamp)]
  end

  defp external_timestamp_candidates(_comment, event) do
    comment = value(event, :comment)
    [value(comment, :updated_at), value(comment, :created_at), value(event, :timestamp)]
  end

  defp value(nil, _key), do: nil

  defp value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(_map, _key), do: nil
end
