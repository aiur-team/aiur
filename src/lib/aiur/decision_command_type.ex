defmodule Aiur.DecisionCommandType do
  @moduledoc """
  Data-driven classification of Command types into the authority and
  reversibility policy they should carry when a request omits those fields.

  A Command's `kind` is a free-form category the requesting agent chooses, so
  the classification must be data rather than an accident of which
  normalization default happened to be used. `Aiur.DecisionValidation`
  consults `for_kind/1` to fill in an omitted `authority`/`reversibility`;
  an explicitly declared field always wins over this table.

  Consequence-based, not topic-based: a re-review request and a PR/ticket
  sequencing question are reversible engineering calls the Executor is
  positioned to answer, so they classify delegable. The pre-OCC
  `legacy_attention` projection keeps its original fail-closed policy so the
  legacy import path is unchanged. Kinds not listed here fall back to the
  request defaults in `Aiur.DecisionValidation` (`supervisor_allowed` +
  `reversible`); a genuinely irreversible, spend, external-publication, or
  product-direction Command must declare that explicitly.
  """

  alias Aiur.Decision

  @type policy :: %{authority: Decision.authority(), reversibility: Decision.reversibility()}

  @classifications %{
    # A re-review request after completed rework ("rework is green, reviewDecision
    # is stuck on a stale review"): the Executor is the intended audience and
    # should answer rather than escalate.
    "rework_review" => %{authority: :supervisor_preferred, reversibility: :reversible},
    # PR/ticket sequencing: how to split work, which PR carries a shared change,
    # what to rebase onto. Reversible engineering calls.
    "sequencing" => %{authority: :supervisor_allowed, reversibility: :reversible},
    # Pre-OCC attention projections are informational visibility signals that were
    # always human-scoped; keep them fail-closed through the legacy import path.
    "legacy_attention" => %{authority: :human_required, reversibility: :irreversible}
  }

  @doc """
  Returns the explicit `%{authority:, reversibility:}` policy for a known
  Command type, or `nil` when the kind is not classified here.
  """
  @spec for_kind(String.t() | nil) :: policy() | nil
  def for_kind(kind) when is_binary(kind) do
    kind
    |> normalize_kind()
    |> then(&Map.get(@classifications, &1))
  end

  def for_kind(_kind), do: nil

  @doc "All known Command-type policies. This table is the classification data."
  @spec classifications() :: %{String.t() => policy()}
  def classifications, do: @classifications

  defp normalize_kind(kind) when is_binary(kind) do
    case String.trim(kind) do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end
end
