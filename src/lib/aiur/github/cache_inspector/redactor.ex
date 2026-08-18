defmodule Aiur.GitHub.CacheInspector.Redactor do
  @moduledoc """
  Strips secret material out of a cached payload before it reaches a browser.

  Built on `Aiur.SecretRedactor` rather than beside it, so the pattern list
  cannot drift into a second, weaker copy — that drift is the reason the shared
  module was extracted in the first place.

  Two things are added on top of the shared patterns.

  **Keys, not only values.** A GitHub response body can carry a credential under
  a name (`token`, `authorization`, `client_secret`) in a shape no pattern
  matches — an App installation token that has not been issued in a recognised
  prefix, or a bearer header copied verbatim. A value under a key that *means*
  secret is dropped on the strength of its name alone, before any pattern is
  consulted. A false positive here costs one hidden field on a debug page; a
  false negative publishes a live credential to whoever the page is shared with.

  **Depth and size bounds.** The payload is arbitrary JSON from an external
  service. Rendering it unbounded turns a deep response into a page that never
  finishes, and the inspector must stay cheap enough that holding it open is
  genuinely free.
  """

  alias Aiur.SecretRedactor

  @max_depth 12
  @max_items 200
  @max_string 4_000
  @dropped "[REDACTED:secret-key]"

  # Substrings, not exact names: GitHub nests the same idea under
  # `access_token`, `token_type`, `x-hub-signature`, and a page that only knew
  # the exact word would render the others.
  @secret_key_fragments ~w(
    token secret password passwd credential authorization auth_header
    signature private_key api_key apikey client_secret session_id cookie
  )

  @doc """
  Redacts a payload of any shape.

  Maps, lists, strings and scalars are handled; anything else is rendered
  through `Aiur.SecretRedactor.safe_inspect/2` rather than passed through, so a
  struct or a pid cannot smuggle text past the pattern list.
  """
  @spec redact(term()) :: term()
  def redact(payload), do: walk(payload, 0)

  @doc "Redacts a single string, leaving `nil` alone."
  @spec scrub(String.t() | nil) :: String.t() | nil
  def scrub(nil), do: nil
  def scrub(value) when is_binary(value), do: value |> SecretRedactor.redact() |> SecretRedactor.redact_urls()
  def scrub(value), do: value

  @doc "True when this key names something that must never render."
  @spec secret_key?(term()) :: boolean()
  def secret_key?(key) do
    downcased = key |> to_string() |> String.downcase()

    Enum.any?(@secret_key_fragments, &String.contains?(downcased, &1))
  end

  defp walk(_value, depth) when depth > @max_depth, do: "[elided: nesting depth]"

  defp walk(value, depth) when is_map(value) and not is_struct(value) do
    value
    |> Enum.take(@max_items)
    |> Map.new(fn {key, inner} ->
      {to_string(key), if(secret_key?(key), do: @dropped, else: walk(inner, depth + 1))}
    end)
    |> note_truncation(map_size(value))
  end

  defp walk(value, depth) when is_list(value) do
    kept = Enum.take(value, @max_items)
    walked = Enum.map(kept, &walk(&1, depth + 1))

    if length(value) > @max_items,
      do: walked ++ ["[elided: #{length(value) - @max_items} more items]"],
      else: walked
  end

  # Scrubbed first, then truncated. Truncating first can cut a credential in
  # half, and half a token no longer matches the pattern that would have
  # replaced it — so the bound would be what published the secret.
  defp walk(value, _depth) when is_binary(value) do
    value
    |> scrub()
    |> String.slice(0, @max_string)
  end

  defp walk(value, _depth) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp walk(value, _depth) when is_atom(value), do: to_string(value)
  defp walk(value, _depth), do: SecretRedactor.safe_inspect(value, @max_string)

  defp note_truncation(walked, original_size) when original_size > @max_items,
    do: Map.put(walked, "__elided__", "#{original_size - @max_items} more keys")

  defp note_truncation(walked, _original_size), do: walked
end
