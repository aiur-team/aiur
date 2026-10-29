defmodule Aiur.Conversation.Session do
  @moduledoc "Session records and append-only start/end lines for a conversation."
  defstruct v: 1,
            session_seq: nil,
            harness: nil,
            provider_session_id: nil,
            aiur_attempt_id: nil,
            aiur_run_id: nil,
            first_pos: nil,
            last_pos: nil,
            started_at: nil,
            ended_at: nil,
            start_reason: nil,
            end_reason: nil,
            transcript_source: nil,
            meta: %{}

  @type t :: %__MODULE__{}

  @spec start_line(t()) :: map()
  def start_line(%__MODULE__{} = session) do
    session
    |> to_json()
    |> Map.drop(["ended_at", "end_reason", "last_pos", "meta"])
    |> Map.put("type", "start")
  end

  @spec end_line(t(), keyword() | map() | String.t() | atom()) :: map()
  def end_line(%__MODULE__{} = session, reason) when is_atom(reason) or is_binary(reason),
    do: end_line(%{session | end_reason: reason}, %{})

  def end_line(%__MODULE__{} = session, attrs) do
    attrs = Map.new(attrs)

    session = %{
      session
      | ended_at: Map.get(attrs, :ended_at, session.ended_at),
        end_reason: Map.get(attrs, :end_reason, session.end_reason),
        last_pos: Map.get(attrs, :last_pos, session.last_pos)
    }

    session
    |> to_json()
    |> Map.take(["v", "session_seq", "ended_at", "end_reason", "last_pos", "meta"])
    |> Map.reject(fn {key, value} -> key == "meta" and value == %{} end)
    |> Map.put("type", "end")
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = session),
    do:
      session
      |> Map.from_struct()
      |> Map.new(fn {key, value} -> {Atom.to_string(key), json_value(value)} end)

  @spec from_json(map() | binary()) :: {:ok, t()} | {:error, :invalid_session}
  def from_json(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, data} -> from_json(data)
      _ -> {:error, :invalid_session}
    end
  end

  def from_json(data) when is_map(data) do
    fields = Map.keys(%__MODULE__{}) -- [:__struct__]

    session =
      struct(
        __MODULE__,
        Enum.map(
          fields,
          &{&1, Map.get(data, Atom.to_string(&1), Map.get(data, &1, Map.fetch!(%__MODULE__{}, &1)))}
        )
      )

    if Map.get(data, "v", Map.get(data, :v)) == 1 and
         valid?(session, Map.get(data, "type", Map.get(data, :type))),
       do: {:ok, session},
       else: {:error, :invalid_session}
  end

  def from_json(_data), do: {:error, :invalid_session}

  defp valid?(session, type) do
    session.v == 1 and positive?(session.session_seq) and type in [nil, "start", "end"] and
      valid_line?(session, type)
  end

  defp valid_line?(session, "end"), do: is_binary(session.end_reason)

  defp valid_line?(session, _type),
    do:
      is_binary(session.harness) and is_binary(session.start_reason) and
        positive?(session.first_pos)

  defp positive?(value), do: is_integer(value) and value > 0
  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp json_value(value), do: value
end
