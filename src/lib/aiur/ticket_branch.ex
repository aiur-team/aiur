defmodule Aiur.TicketBranch do
  @moduledoc """
  Canonical Aiur ticket branch generation and parsing.

  New tracker tickets receive a readable title suffix while the numeric ticket
  id remains the stable identity used by events and PR routing. Existing
  `aiur/<id>` branches remain valid indefinitely.
  """

  @transliterations [
    {"ß", "ss"},
    {"æ", "ae"},
    {"œ", "oe"},
    {"ø", "o"},
    {"đ", "d"},
    {"ð", "d"},
    {"ħ", "h"},
    {"ı", "i"},
    {"ł", "l"},
    {"ŋ", "n"},
    {"þ", "th"},
    {"ŧ", "t"}
  ]

  @ticket_branch ~r/\Aaiur\/([1-9]\d*)(?:-[a-z0-9]+(?:-[a-z0-9]+)*)?\z/
  @heads_prefix "refs/heads/"

  @doc """
  Returns the canonical branch for a newly created ticket.

  The suffix contains at most four normalized title words. An unusable title
  intentionally produces the compatible legacy `aiur/<identifier>` branch.
  """
  @spec branch_name(String.t() | integer(), String.t() | term()) :: String.t()
  def branch_name(identifier, title) do
    legacy = legacy_branch_name(identifier)

    case title_slug(title) do
      "" -> legacy
      slug -> legacy <> "-" <> slug
    end
  end

  @doc "Returns the legacy, identifier-only Aiur branch name."
  @spec legacy_branch_name(String.t() | integer()) :: String.t()
  def legacy_branch_name(identifier), do: "aiur/" <> to_string(identifier)

  @doc "Returns the normalized, at-most-four-word title suffix, or an empty string."
  @spec title_slug(term()) :: String.t()
  def title_slug(title) when is_binary(title) do
    title
    |> String.normalize(:nfd)
    |> String.downcase()
    |> transliterate()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.split()
    |> Enum.take(4)
    |> Enum.join("-")
  end

  def title_slug(_title), do: ""

  @doc "Returns a ticket's numeric id from a legacy or suffixed branch, or nil."
  @spec ticket_id(term()) :: String.t() | nil
  def ticket_id(branch) when is_binary(branch) do
    case Regex.run(@ticket_branch, branch) do
      [_, identifier] -> identifier
      _ -> nil
    end
  end

  def ticket_id(_branch), do: nil

  @doc "Returns a ticket's numeric id from a full heads ref, or nil."
  @spec ticket_id_from_ref(term()) :: String.t() | nil
  def ticket_id_from_ref(@heads_prefix <> branch), do: ticket_id(branch)
  def ticket_id_from_ref(_ref), do: nil

  @doc "Whether `branch` belongs to the supplied numeric ticket identifier."
  @spec ticket_branch?(term(), String.t() | integer()) :: boolean()
  def ticket_branch?(branch, identifier), do: ticket_id(branch) == to_string(identifier)

  defp transliterate(value) do
    Enum.reduce(@transliterations, value, fn {source, replacement}, text ->
      String.replace(text, source, replacement)
    end)
  end
end
