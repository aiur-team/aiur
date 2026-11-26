defmodule Aiur.ControlCLI.MediaSpec do
  @moduledoc """
  Parses `aiur command request --media` values into untrusted media items.

  A spec is `<file|https-url>[,kind=...][,mime=...][,alt=...][,caption=...][,option=<id>]`.
  Only the item's shape is built here: the item goes through
  `Aiur.Commands.Media.normalize/2` in the request validation, so safe roots,
  the URL allowlist and the expiring-URL refusal apply unchanged.
  """

  @keys ~w(kind mime alt caption option)
  # Split only before a known key, so alt text and captions may contain commas.
  @separator ~r/,(?=(?:kind|mime|alt|caption|option)=)/

  @spec parse(String.t()) :: {:ok, {String.t() | nil, map()}} | {:error, String.t()}
  def parse(spec) when is_binary(spec) do
    [locator | pairs] = String.split(spec, @separator)

    with :ok <- present(locator),
         {:ok, attrs} <- attrs(pairs) do
      mime = attrs["mime"] || mime(attrs["kind"], locator)

      item =
        %{locator: locator, mime_type: mime, kind: attrs["kind"] || kind(mime), alt_text: attrs["alt"], caption: attrs["caption"]}
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, {attrs["option"], item}}
    end
  end

  defp present(""), do: {:error, "--media expects <file|https-url>[,kind=...,alt=...,caption=...,option=...]"}
  defp present(_locator), do: :ok

  defp attrs(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
      case String.split(pair, "=", parts: 2) do
        [key, value] when key in @keys and value != "" -> {:cont, {:ok, Map.put(acc, key, value)}}
        _other -> {:halt, {:error, "--media attribute must be one of kind, mime, alt, caption, option with a value"}}
      end
    end)
  end

  # An embed URL names a page, not a file; `Media.normalize/2` defaults it to text/html.
  defp mime("embed", _locator), do: nil
  defp mime(_kind, locator), do: locator |> URI.parse() |> Map.get(:path) |> to_string() |> MIME.from_path()

  defp kind(mime) when mime in ["image/gif", "image/apng"], do: "animated_image"
  defp kind("image/" <> _rest), do: "image"
  defp kind("video/" <> _rest), do: "video"
  defp kind("audio/" <> _rest), do: "audio"
  defp kind("text/html"), do: "embed"
  defp kind(_mime), do: nil
end
