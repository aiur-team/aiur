defmodule Aiur.AllowedContributors.Ledger do
  @moduledoc """
  Restart-durable intake state: which issue numbers already received a
  terminal decision, and the last allow-list commit the operator was shown.

  The seen set is what makes "exactly one wake per issue" hold across both
  producers (webhook and poll) and across daemon restarts; entries older than
  seven days are pruned, far beyond the poll producer's 24-hour horizon. The
  remembered allow-list SHA is what makes the change alert fire once per
  merged change rather than once per boot.
  """

  alias Aiur.JsonStore

  @retention_s 7 * 24 * 3600

  @type t :: %{seen: %{optional(String.t()) => integer()}, sha: String.t() | nil, entries: [String.t()]}

  @spec load(Path.t()) :: t()
  def load(path) do
    case JsonStore.read(path, nil) do
      {:ok, %{"seen" => seen} = data} when is_map(seen) ->
        %{
          seen: Map.filter(seen, fn {key, at} -> is_binary(key) and is_integer(at) end),
          sha: string_or_nil(data["sha"]),
          entries: Enum.filter(List.wrap(data["entries"]), &is_binary/1)
        }

      _missing_or_corrupt ->
        %{seen: %{}, sha: nil, entries: []}
    end
  end

  @spec seen?(t(), pos_integer()) :: boolean()
  def seen?(ledger, number), do: Map.has_key?(ledger.seen, Integer.to_string(number))

  @spec mark_seen(t(), pos_integer(), integer()) :: t()
  def mark_seen(ledger, number, now_s) do
    seen =
      ledger.seen
      |> Map.filter(fn {_number, at} -> now_s - at < @retention_s end)
      |> Map.put(Integer.to_string(number), now_s)

    %{ledger | seen: seen}
  end

  @spec put_allowlist(t(), String.t() | nil, [String.t()]) :: t()
  def put_allowlist(ledger, sha, entries), do: %{ledger | sha: sha, entries: entries}

  @spec save(t(), Path.t()) :: :ok
  def save(ledger, path) do
    File.mkdir_p!(Path.dirname(path))
    JsonStore.write!(path, %{"seen" => ledger.seen, "sha" => ledger.sha, "entries" => ledger.entries})
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil
end
