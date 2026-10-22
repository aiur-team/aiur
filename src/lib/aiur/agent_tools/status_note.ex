defmodule Aiur.AgentTools.StatusNote do
  @moduledoc """
  Validator for the agent status note sent with
  `emit_event(name: "progress.status", ...)` (see `Aiur.AgentStatusNote`
  for why the note exists and where it is kept).

  An unknown field, a non-string value, an over-long field or a payload over
  1,280 bytes, or a `message` over 200 bytes or on more than one line, is rejected with an error that names the limit, so the agent can
  fix it. Every accepted string goes through `Aiur.SecretRedactor`, so a token
  never reaches the bus or the store.
  """

  alias Aiur.SecretRedactor

  # Every field at its own cap, plus keys and the longest `updated_reason`,
  # encodes to about 1,201 bytes, so the whole-payload cap leaves headroom for
  # that instead of rejecting a note whose fields are each within limits.
  @max_payload_bytes 1_280
  @max_message_bytes 200
  @field_limits [
    {"doing", 200},
    {"why", 200},
    {"next", 200},
    {"waiting_on", 120},
    {"asks", 200},
    {"risks", 160},
    {"pr", 16}
  ]
  @fields Enum.map(@field_limits, &elem(&1, 0))
  @updated_reasons ~w(phase long_step command turn_end refresh)

  @type note :: %{required(String.t()) => String.t()}

  @doc """
  Validate and redact a status note.

  Returns `{:ok, message, payload}` with the redacted one-line message and
  a payload holding every field as a string (missing optional fields
  become `""`), or `{:error, {:status_note_invalid, text}}` where `text`
  names the broken rule and its limit.
  """
  @spec validate(String.t(), map()) :: {:ok, String.t(), note()} | {:error, {:status_note_invalid, String.t()}}
  def validate(message, payload) when is_binary(message) and is_map(payload) do
    payload = Map.new(payload, fn {key, value} -> {to_string(key), value} end)

    with :ok <- check_message(message),
         :ok <- check_payload_size(payload),
         :ok <- check_known_fields(payload),
         {:ok, fields} <- check_fields(payload),
         {:ok, reason} <- check_updated_reason(payload) do
      {:ok, SecretRedactor.redact(message), Map.put(fields, "updated_reason", reason)}
    end
  end

  defp check_message(message) do
    cond do
      String.contains?(message, ["\n", "\r"]) -> invalid("status note `message` must be one line.")
      byte_size(message) > @max_message_bytes -> invalid("status note `message` is #{byte_size(message)} bytes; the limit is #{@max_message_bytes} bytes.")
      true -> :ok
    end
  end

  defp check_payload_size(payload) do
    size = payload |> Jason.encode!() |> byte_size()

    if size > @max_payload_bytes,
      do: invalid("status note payload is #{size} bytes; the limit is #{@max_payload_bytes} bytes. Shorten the fields."),
      else: :ok
  end

  defp check_known_fields(payload) do
    case Map.keys(payload) -- ["updated_reason" | @fields] do
      [] -> :ok
      unknown -> invalid("unknown status note field(s) #{Enum.join(unknown, ", ")}; allowed: #{Enum.join(@fields, ", ")}, updated_reason.")
    end
  end

  defp check_fields(payload) do
    Enum.reduce_while(@field_limits, {:ok, %{}}, fn {field, limit}, {:ok, acc} ->
      case field_value(field, Map.get(payload, field)) do
        {:ok, value} when byte_size(value) > limit ->
          {:halt, invalid("status note `#{field}` is #{byte_size(value)} bytes; the limit is #{limit} bytes.")}

        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, field, SecretRedactor.redact(value))}}

        :error ->
          {:halt, invalid("status note `#{field}` must be a string.")}
      end
    end)
    |> require_doing()
  end

  defp field_value(_field, nil), do: {:ok, ""}
  defp field_value(_field, value) when is_binary(value), do: {:ok, String.trim(value)}
  defp field_value("pr", value) when is_integer(value) and value > 0, do: {:ok, Integer.to_string(value)}
  defp field_value(_field, _value), do: :error

  defp require_doing({:ok, %{"doing" => ""}}), do: invalid("status note `doing` is required: say what you are doing right now.")
  defp require_doing(result), do: result

  defp check_updated_reason(payload) do
    reason = Map.get(payload, "updated_reason")

    if reason in @updated_reasons,
      do: {:ok, reason},
      else: invalid("status note `updated_reason` must be one of: #{Enum.join(@updated_reasons, ", ")}.")
  end

  defp invalid(text), do: {:error, {:status_note_invalid, text}}
end
