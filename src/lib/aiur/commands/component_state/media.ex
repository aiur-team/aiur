defmodule Aiur.Commands.ComponentState.Media do
  @moduledoc """
  The `"media"` list carried by the shared Command component contract.

  A component's `"media"` is what a dashboard card or an embedding host may
  render. The list stays additive so the contract published before typed Command
  media existed keeps working:

    * typed items are the public projection from `Aiur.Commands.Media.public/1`,
      so an image, animated image, video or audio item arrives with its kind,
      MIME type, safe locator and alt/caption text — and a local file arrives as
      an opaque `attachment` reference, never a filesystem path;
    * artifact references keep the pre-existing `kind` + `value` shape (`url` or
      `path`), so a host that already renders them is unaffected.

  A renderer tells the two apart by the presence of `"locator"`: a typed item
  always carries one, an artifact reference never does. `Media.public/1` is
  idempotent, so a projection that already holds public items is safe to pass
  through it again.
  """

  alias Aiur.Commands.Media

  @doc """
  The renderable media list for one Command projection.

  Accepts the API projection (string keys) and the dashboard row (atom keys).
  """
  @spec list(term()) :: [map()]
  def list(projection) when is_map(projection) do
    typed(projection) ++ artifacts(projection)
  end

  def list(_projection), do: []

  @doc """
  The optional `"media"` addition for one option.

  An option without typed media returns `%{}`, so a text-only option keeps the
  component shape it had before this contract existed.
  """
  @spec option_media(term()) :: %{optional(String.t()) => [map()]}
  def option_media(option) when is_map(option) do
    case typed(option) do
      [] -> %{}
      items -> %{"media" => items}
    end
  end

  def option_media(_option), do: %{}

  # `Media.public/1` is the boundary that refuses an unsafe or expiring locator
  # and rewrites a local path into an attachment id, so this module never repeats
  # those checks.
  defp typed(projection) do
    projection
    |> fetch("media")
    |> Media.public()
  end

  defp artifacts(projection) do
    projection
    |> fetch("artifacts")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(fn artifact ->
      case {text(artifact, "kind"), text(artifact, "value")} do
        {nil, _value} -> []
        {_kind, nil} -> []
        {kind, value} -> [%{"kind" => kind, "value" => value}]
      end
    end)
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> map |> atom_key(key) |> then(&(&1 && Map.get(map, &1)))
    end
  end

  defp atom_key(_map, key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp text(map, key) do
    case fetch(map, key) do
      value when is_binary(value) -> value
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _other -> nil
    end
  end
end
