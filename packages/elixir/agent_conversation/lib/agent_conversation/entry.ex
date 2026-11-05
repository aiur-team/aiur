defmodule AgentConversation.Entry do
  @moduledoc """
  The conversation entry shape the component renders.

  `normalize/1` accepts the maps or structs a transport returns and produces a
  plain map with every key the components read, so a host may keep its own entry
  record without widening this package's contract. Attachments are classified
  through `AgentConversation.Media`.
  """

  alias AgentConversation.Media

  @kinds ~w(message reasoning command diff tool_result operator_message system gap)
  @artifact_keys ~w(artifacts media attachments)

  @type t :: %{
          pos: pos_integer() | nil,
          id: term(),
          kind: String.t(),
          role: String.t(),
          body: String.t(),
          output: String.t() | nil,
          meta: map(),
          observed_at: DateTime.t() | String.t() | nil,
          redacted: boolean(),
          body_truncated: boolean(),
          output_truncated: boolean(),
          media: [Media.t()]
        }

  @doc "Every entry kind the component has a dedicated rendering for."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Normalizes one entry.

  Missing `:kind` and `:role` become `"system"` so an unfamiliar payload renders
  as a stated system row instead of an empty article. Attachments are read from
  `"artifacts"`, `"media"` or `"attachments"` in the entry metadata.
  """
  @spec normalize(map()) :: t()
  def normalize(entry) when is_map(entry) do
    meta = get(entry, :meta) || %{}

    %{
      pos: get(entry, :pos),
      id: get(entry, :id) || get(entry, :pos),
      kind: to_string(get(entry, :kind) || "system"),
      role: to_string(get(entry, :role) || "system"),
      body: to_string(get(entry, :body) || ""),
      output: get(entry, :output),
      meta: meta,
      observed_at: get(entry, :observed_at) || get(entry, :occurred_at),
      redacted: get(entry, :redacted) == true,
      body_truncated: get(entry, :body_truncated) == true,
      output_truncated: get(entry, :output_truncated) == true,
      media: media(entry, meta)
    }
  end

  @doc "The stable identity of an entry for de-duplication."
  @spec identity(t() | map()) :: term()
  def identity(%{id: id}) when not is_nil(id), do: {:id, id}
  def identity(%{pos: pos}), do: {:pos, pos}
  def identity(_entry), do: {:unknown, make_ref()}

  @doc "Reads a metadata value by atom or string key."
  @spec meta(map(), atom()) :: term()
  def meta(%{meta: meta}, key) when is_map(meta), do: Map.get(meta, key, Map.get(meta, Atom.to_string(key)))
  def meta(_entry, _key), do: nil

  @doc "Whether the entry carries a human-visible attachment."
  @spec artifacts?(t()) :: boolean()
  def artifacts?(%{media: media}), do: media != []

  @artifact_atoms [:artifacts, :media, :attachments]

  defp media(entry, meta) do
    inline = Enum.flat_map(@artifact_atoms, &Media.classify_all(Map.get(entry, &1)))
    attached = Enum.flat_map(@artifact_keys, &Media.classify_all(Map.get(meta, &1)))
    inline ++ attached
  end

  defp get(entry, key) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end
end
