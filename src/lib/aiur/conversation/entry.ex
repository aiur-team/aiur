defmodule Aiur.Conversation.Entry do
  @moduledoc "Conversation entries, transcript provenance, stable deduplication and UTF-8 bounds."

  alias Aiur.LiveConversation.Source

  @max_body_bytes 65_536
  @max_tool_body_bytes 16_384
  @kinds ~w(message reasoning command diff tool_result operator_message system gap)
  @roles ~w(agent tool operator executor_operator provider_input system)
  @ref_keys ~w(provider_msg_id provider_item_id tool_call_id turn_id delivery_id)a
  @meta_keys ~w(exit_code cwd tool success provider_role alert origin)a

  defstruct v: 1,
            pos: nil,
            session_seq: nil,
            observed_at: nil,
            occurred_at: nil,
            kind: nil,
            role: nil,
            body: "",
            body_truncated: false,
            output: nil,
            output_truncated: false,
            refs: %{},
            meta: %{}

  @type t :: %__MODULE__{}

  @spec from_transcript_event(map(), keyword()) :: {:ok, t()} | :skip
  def from_transcript_event(event, opts \\ []) do
    if get(event, :kind) in [:assistant_delta, "assistant_delta"] and
         get(event, :role) in [:assistant, "assistant"] do
      :skip
    else
      map_event(event, opts)
    end
  end

  @spec bound(t(), keyword()) :: t()
  def bound(%__MODULE__{} = entry, _opts \\ []) do
    limit =
      if entry.kind in ["command", "tool_result"], do: @max_tool_body_bytes, else: @max_body_bytes

    {body, body_truncated} = bound_text(entry.body, limit)
    {output, output_truncated} = bound_text(entry.output, limit)

    %{
      entry
      | body: body,
        body_truncated: entry.body_truncated or body_truncated,
        output: output,
        output_truncated: entry.output_truncated or output_truncated
    }
  end

  @spec dedup_key(t() | map()) :: String.t()
  def dedup_key(entry) do
    refs = get(entry, :refs) || %{}
    role = get(entry, :role)

    key =
      cond do
        present?(get(refs, :provider_msg_id)) ->
          {:msg, role, get(refs, :provider_msg_id)}

        present?(get(refs, :provider_item_id)) ->
          {:item, role, get(refs, :provider_item_id)}

        present?(get(refs, :tool_call_id)) ->
          {:call, role, get(refs, :tool_call_id)}

        true ->
          {:fallback, role, get(refs, :turn_id), timestamp(get(entry, :occurred_at)), get(entry, :body)}
      end

    Source.opaque_id("ent_", key)
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = entry) do
    entry
    |> bound()
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), json_value(value)} end)
  end

  @spec from_json(map() | binary()) :: {:ok, t()} | {:error, :invalid_entry}
  def from_json(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, data} -> from_json(data)
      _ -> {:error, :invalid_entry}
    end
  end

  def from_json(data) when is_map(data) do
    entry =
      struct(
        __MODULE__,
        Enum.map(
          Map.keys(%__MODULE__{}) -- [:__struct__],
          &{&1, get(data, &1, Map.fetch!(%__MODULE__{}, &1))}
        )
      )

    if get(data, :v) == 1 and valid_entry?(entry) do
      refs =
        Map.new(@ref_keys, &{&1, get(entry.refs, &1)})
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, %{entry | refs: refs, meta: decode_meta(entry.meta)}}
    else
      {:error, :invalid_entry}
    end
  end

  def from_json(_data), do: {:error, :invalid_entry}

  defp decode_meta(meta) do
    Enum.reduce(@meta_keys, meta, fn key, decoded ->
      string = Atom.to_string(key)

      if Map.has_key?(decoded, string),
        do: decoded |> Map.delete(string) |> Map.put(key, decoded[string]),
        else: decoded
    end)
  end

  defp map_event(event, opts) do
    payload = get(event, :payload) || %{}

    case mapping(to_string(get(event, :role)), payload, Keyword.get(opts, :subject_kind, :worker)) do
      nil ->
        :skip

      {kind, role, meta} ->
        refs = refs(event, payload, kind)
        body = event_body(event, payload, kind)
        output = if kind in ["command", "diff", "tool_result"], do: get(payload, :output)

        {:ok,
         bound(%__MODULE__{
           kind: kind,
           role: role,
           body: body,
           output: output,
           occurred_at: timestamp(get(event, :timestamp)),
           refs: refs,
           meta: meta
         })}
    end
  end

  defp mapping("assistant", _payload, _subject), do: {"message", "agent", %{}}
  defp mapping("reasoning", _payload, _subject), do: {"reasoning", "agent", %{}}

  defp mapping("command", payload, _subject),
    do: {"command", "agent", %{exit_code: get(payload, :exit_code), cwd: get(payload, :workdir)}}

  defp mapping("tool", payload, _subject) do
    kind = if get(payload, :tool) == "edit", do: "diff", else: "tool_result"
    {kind, "tool", %{tool: get(payload, :tool), success: get(payload, :success)}}
  end

  defp mapping("user", payload, subject) when subject in [:executor, "executor"],
    do: {"operator_message", "executor_operator", if(get(payload, :origin) == :remote, do: %{origin: "remote_control"}, else: %{})}

  defp mapping("user", payload, _subject) do
    if present?(get(payload, :delivery_id)),
      do: {"operator_message", "operator", %{}},
      else: {"system", "provider_input", %{provider_role: "user"}}
  end

  defp mapping("system", _payload, _subject), do: {"system", "system", %{}}
  defp mapping("alert", _payload, _subject), do: {"system", "system", %{alert: true}}
  defp mapping(_role, _payload, _subject), do: nil

  defp refs(event, payload, kind) do
    base = %{
      provider_msg_id: get(event, :msg_id),
      provider_item_id: get(payload, :provider_item_id),
      turn_id: get(event, :turn_id),
      delivery_id: get(payload, :delivery_id)
    }

    base =
      if kind in ["command", "diff", "tool_result"],
        do: Map.put(base, :tool_call_id, get(payload, :tool_call_id) || get(event, :msg_id)),
        else: base

    Map.reject(base, fn {_key, value} -> is_nil(value) end)
  end

  defp event_body(event, payload, "command"),
    do: get(payload, :command) || get(event, :body) || ""

  defp event_body(_event, payload, "diff"), do: get(payload, :title) || ""
  defp event_body(event, _payload, _kind), do: get(event, :body) || ""

  defp bound_text(nil, _limit), do: {nil, false}

  defp bound_text(text, limit) when is_binary(text) do
    text = scrub(text)

    if byte_size(text) <= limit do
      {text, false}
    else
      cap = div(limit, 4)
      first = utf8_prefix(text, cap)
      last = utf8_suffix(text, cap)
      omitted = byte_size(text) - byte_size(first) - byte_size(last)
      {first <> "\n…[#{omitted} bytes omitted]…\n" <> last, true}
    end
  end

  defp scrub(text), do: scrub(text, [])
  defp scrub(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp scrub(<<char::utf8, rest::binary>>, acc), do: scrub(rest, [<<char::utf8>> | acc])
  defp scrub(<<_byte, rest::binary>>, acc), do: scrub(rest, ["�" | acc])

  defp utf8_prefix(text, cap) do
    prefix = binary_part(text, 0, cap)
    trim_prefix(prefix)
  end

  defp trim_prefix(prefix) do
    if String.valid?(prefix),
      do: prefix,
      else: trim_prefix(binary_part(prefix, 0, byte_size(prefix) - 1))
  end

  defp utf8_suffix(text, cap),
    do: text |> binary_part(byte_size(text) - cap, cap) |> trim_suffix()

  defp trim_suffix(suffix) do
    if String.valid?(suffix),
      do: suffix,
      else: trim_suffix(binary_part(suffix, 1, byte_size(suffix) - 1))
  end

  defp valid_entry?(entry) do
    Enum.all?([
      entry.v == 1,
      entry.kind in @kinds,
      entry.role in @roles,
      valid_text?(entry.body),
      is_nil(entry.output) or valid_text?(entry.output),
      is_boolean(entry.body_truncated),
      is_boolean(entry.output_truncated),
      valid_refs?(entry.refs),
      is_map(entry.meta),
      optional_positive?(entry.pos),
      optional_positive?(entry.session_seq)
    ])
  end

  defp valid_text?(text), do: is_binary(text) and String.valid?(text)

  defp valid_refs?(refs) when is_map(refs),
    do: Enum.all?(refs, fn {_key, value} -> is_nil(value) or is_binary(value) end)

  defp valid_refs?(_refs), do: false

  defp optional_positive?(nil), do: true
  defp optional_positive?(value), do: is_integer(value) and value > 0
  defp present?(value), do: is_binary(value) and value != ""
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(value), do: value
  defp json_value(%DateTime{} = value), do: timestamp(value)

  defp json_value(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_value(item)} end)

  defp json_value(value), do: value

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
