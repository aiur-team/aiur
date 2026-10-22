defmodule Aiur.AgentStatusNote do
  @moduledoc """
  The agent status note: a short, machine-readable "doing / why / next /
  waiting on / asks / risks / pr" note the coding agent keeps current with
  `emit_event(name: "progress.status", ...)`.

  It exists so a reader (the Executor, the phone home view, the voice
  assistant's status card) can answer "what are you doing and why" from a
  note the agent already wrote, without stopping the agent to ask.

  `validate/2` is the gate in front of the publish: an unknown field, a
  non-string value, an over-long field or a payload over
  #{1_200} bytes is rejected with an error that names the limit, and every
  accepted string is passed through `Aiur.SecretRedactor` so a token never
  reaches the bus or the store.

  `record/3` keeps the latest note per ticket in a small JSON file under
  the daemon-owned log root (not the agent-writable workspace), with a
  monotonic `version` and an `observed_at` timestamp. `latest/2` reads it.
  """

  alias Aiur.Config.Paths, as: ConfigPaths
  alias Aiur.IssueLog.Paths, as: IssueLogPaths
  alias Aiur.SecretRedactor

  @max_payload_bytes 1_200
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

  @type note :: %{required(String.t()) => term()}

  @doc "Byte cap on the whole JSON-encoded note payload."
  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: @max_payload_bytes

  @doc "Allowed `updated_reason` values."
  @spec updated_reasons() :: [String.t()]
  def updated_reasons, do: @updated_reasons

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

    with :ok <- check_payload_size(payload),
         :ok <- check_known_fields(payload),
         {:ok, fields} <- check_fields(payload),
         {:ok, reason} <- check_updated_reason(payload) do
      {:ok, SecretRedactor.redact(message), Map.put(fields, "updated_reason", reason)}
    end
  end

  @doc """
  Store `note` as the latest note for the ticket `identifier`, bumping the
  version. Returns the stored note with `version` and `observed_at`.

  Options: `:root` (directory; defaults to `<log-root>/status-notes`) and
  `:now` (`DateTime`, for tests).
  """
  @spec record(String.t(), String.t(), note(), keyword()) :: {:ok, note()} | {:error, term()}
  def record(identifier, message, note, opts \\ []) when is_binary(identifier) and is_binary(message) and is_map(note) do
    path = note_path(identifier, opts)

    version =
      case latest_at(path) do
        {:ok, %{"version" => previous}} when is_integer(previous) -> previous + 1
        _none -> 1
      end

    observed_at = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.to_iso8601()
    stored = note |> Map.put("message", message) |> Map.put("version", version) |> Map.put("observed_at", observed_at)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, Jason.encode!(stored)),
         :ok <- File.rename(tmp, path) do
      {:ok, stored}
    end
  end

  @doc """
  The latest stored note for the ticket `identifier`, or `:none` when the
  agent has not written one (or the stored file is unreadable).
  """
  @spec latest(String.t(), keyword()) :: {:ok, note()} | :none
  def latest(identifier, opts \\ []) when is_binary(identifier) do
    identifier |> note_path(opts) |> latest_at()
  end

  defp latest_at(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = note} <- Jason.decode(body) do
      {:ok, note}
    else
      _missing_or_corrupt -> :none
    end
  end

  defp note_path(identifier, opts) do
    root = Keyword.get_lazy(opts, :root, fn -> Path.join(ConfigPaths.log_root_dir(), "status-notes") end)
    Path.join(root, "#{IssueLogPaths.configured_repository_scope()}.#{ConfigPaths.sanitize(identifier)}.json")
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
