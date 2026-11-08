defmodule Aiur.Heroicons do
  @moduledoc "Shared resolver for the vendored Heroicons v2 outline set."

  @generic_icon "squares-2x2"
  @aliases %{"bug" => "bug-ant", "pen" => "paint-brush", "server" => "server-stack", "docs" => "book-open"}
  @outline_dir "deps/heroicons/optimized/24/outline"
  @svgs (for path <- Path.wildcard(Path.join(@outline_dir, "*.svg")), into: %{} do
           name = path |> Path.basename(".svg")
           @external_resource path
           svg = path |> File.read!() |> String.replace(~r/\s+data-slot="icon"/, "") |> String.trim()
           {name, svg}
         end)
  @icons Map.keys(@svgs)

  @spec names() :: [String.t()]
  def names, do: @icons

  @spec valid?(term()) :: boolean()
  def valid?(name) when is_binary(name), do: name in @icons or Map.has_key?(@aliases, name)
  def valid?(_name), do: false

  @spec canonical_name(term()) :: String.t()
  def canonical_name(name) when is_binary(name), do: Map.get(@aliases, name, name)
  def canonical_name(_name), do: @generic_icon

  @spec svg(term()) :: String.t()
  def svg(name) when is_binary(name) do
    name = canonical_name(name)
    Map.get(@svgs, name, Map.fetch!(@svgs, @generic_icon))
  end

  def svg(_name), do: Map.fetch!(@svgs, @generic_icon)

  @spec generic_name() :: String.t()
  def generic_name, do: @generic_icon
end
