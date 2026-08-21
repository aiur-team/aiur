defmodule Aiur.Upgrade.Version do
  @moduledoc """
  Pure semver comparison for the `aiur run` upgrade notice.

  The npm registry distributes aiur across three dist-tags — `latest`, `next`,
  and `nightly` — where the live `latest` (0.0.3) is *older* than published
  `nightly` pre-releases (0.0.5-nightly.<sha>). Any comparison that ignores
  prerelease ordering would therefore tell a nightly user to "upgrade" to an
  older version. This module implements the ordering the notice relies on:

    * `0.0.5-nightly.x` < `0.0.5` (a release outranks a same-core prerelease)
    * `0.0.5-nightly.x` > `0.0.3` (a prerelease can still be newer than an
      older release)
    * within a prerelease channel, numeric/dotted identifiers compare per semver

  Parse rejects versions with trailing junk (control/ANSI bytes included) so a
  hostile registry string is never compared as "newer" or printed verbatim.
  """

  @type pre_identifier :: String.t() | non_neg_integer()
  @type t :: %{
          major: non_neg_integer(),
          minor: non_neg_integer(),
          patch: non_neg_integer(),
          pre: [pre_identifier()]
        }

  @version_re ~r/\A(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?\z/

  @doc """
  Parse a semver string. Rejects anything that is not a well-formed
  `X.Y.Z[-pre][+build]`; returns `:error` on trailing junk or non-binary input.
  """
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(value) when is_binary(value) do
    case Regex.run(@version_re, String.trim(value)) do
      [_, major, minor, patch] ->
        {:ok,
         %{
           major: String.to_integer(major),
           minor: String.to_integer(minor),
           patch: String.to_integer(patch),
           pre: []
         }}

      [_, major, minor, patch, pre] ->
        {:ok,
         %{
           major: String.to_integer(major),
           minor: String.to_integer(minor),
           patch: String.to_integer(patch),
           pre: parse_pre(pre)
         }}

      _ ->
        :error
    end
  end

  def parse(_other), do: :error

  @doc """
  Three-way semver comparison: `:lt`, `:eq`, `:gt`, or `:incomparable` when
  either input does not parse.
  """
  @spec compare(term(), term()) :: :lt | :eq | :gt | :incomparable
  def compare(a, b) do
    with {:ok, pa} <- parse(a),
         {:ok, pb} <- parse(b) do
      cond do
        pa.major != pb.major -> compare_atom(pa.major, pb.major)
        pa.minor != pb.minor -> compare_atom(pa.minor, pb.minor)
        pa.patch != pb.patch -> compare_atom(pa.patch, pb.patch)
        true -> compare_pre(pa.pre, pb.pre)
      end
    else
      _ -> :incomparable
    end
  end

  @doc "True when `a` is strictly newer than `b`. Never true for unparseable input."
  @spec newer?(term(), term()) :: boolean()
  def newer?(a, b), do: compare(a, b) == :gt

  defp parse_pre(pre) do
    pre
    |> String.split(".")
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, ""} -> n
        _ -> part
      end
    end)
  end

  defp compare_pre([], []), do: :eq
  # A release outranks a same-core prerelease.
  defp compare_pre([], _other), do: :gt
  defp compare_pre(_other, []), do: :lt
  defp compare_pre(a, b), do: compare_identifiers(a, b)

  defp compare_identifiers([a | at], [b | bt]) do
    case compare_identifier(a, b) do
      :eq -> compare_identifiers(at, bt)
      other -> other
    end
  end

  defp compare_identifiers([], []), do: :eq
  # A shorter identifier list sorts lower.
  defp compare_identifiers([], _bt), do: :lt
  defp compare_identifiers(_at, []), do: :gt

  defp compare_identifier(a, b) when is_integer(a) and is_integer(b), do: compare_atom(a, b)
  # Numeric identifiers always sort below alphanumeric ones.
  defp compare_identifier(a, _b) when is_integer(a), do: :lt
  defp compare_identifier(_a, b) when is_integer(b), do: :gt
  defp compare_identifier(a, b), do: compare_atom(a, b)

  defp compare_atom(a, b) when a < b, do: :lt
  defp compare_atom(a, b) when a > b, do: :gt
  defp compare_atom(_a, _b), do: :eq
end
