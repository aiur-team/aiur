defmodule Aiur.Opencode.Style do
  @moduledoc """
  Visual framing helpers for chat-pane content. Uses Markdown
  blockquote (`> …`) so dimmed rows share the same left-margin bar
  opencode-attach renders for `:system` and `:alert` deltas — one
  visual vocabulary for everything that isn't agent prose.
  """

  @doc """
  Prefix `text` with a Markdown blockquote so each line renders dimmed
  in the opencode-attach pane. Multi-line text gets the prefix on
  every line so the bar continues unbroken.
  """
  @spec dim(String.t()) :: String.t()
  def dim(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("> " <> &1))
  end
end
