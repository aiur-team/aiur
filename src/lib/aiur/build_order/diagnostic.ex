defmodule Aiur.BuildOrder.Diagnostic do
  @moduledoc """
  A bounded, accessible explanation of a Build Order contract concern.

  Diagnostics deliberately contain a stable code and controlled text rather
  than the untrusted provider value that caused the concern.
  """

  @type code :: atom()

  @type t :: %__MODULE__{code: code(), text: String.t()}

  defstruct [:code, :text]

  @spec new(code()) :: t()
  def new(code) when is_atom(code), do: %__MODULE__{code: code, text: text_for(code)}

  @provider_sourced [
    :call_budget_exhausted,
    :page_budget_exhausted,
    :pagination_mismatch,
    :provider_schema,
    :provider_unavailable
  ]

  @doc """
  Whether a diagnostic records a failure to read from the provider rather than a
  defect in the Build Order itself.

  A provider-sourced diagnostic says "we could not fetch this"; every other code
  says "this is malformed". The two demand opposite operator responses, so a
  structural verdict must never be derived from a provider-sourced diagnostic.
  """
  @spec provider_sourced?(term()) :: boolean()
  def provider_sourced?(%__MODULE__{code: code}), do: code in @provider_sourced
  def provider_sourced?(_diagnostic), do: false

  defp text_for(:ambiguous_complexity), do: "Complexity label is ambiguous."
  defp text_for(:ambiguous_lane), do: "Build lane label is ambiguous."
  defp text_for(:ambiguous_marker), do: "Planning marker is ambiguous."
  defp text_for(:ambiguous_phase), do: "Phase label is ambiguous."
  defp text_for(:catalog_overflow), do: "Too many catalog roots were supplied."
  defp text_for(:call_budget_exhausted), do: "The provider call budget was exhausted."
  defp text_for(:connection_overflow), do: "A dependency connection exceeds the supported bound."
  defp text_for(:duplicate_identity), do: "Provider records repeat a canonical identity."
  defp text_for(:external_dependency), do: "Dependency is outside the configured repository."
  defp text_for(:invalid_dependency), do: "Dependency data is unavailable."
  defp text_for(:invalid_endpoint_locator), do: "A native endpoint does not match its canonical locator."
  defp text_for(:invalid_complexity), do: "Complexity label is invalid."
  defp text_for(:invalid_identity), do: "Repository-qualified identity is invalid."
  defp text_for(:invalid_label), do: "Planning label is invalid."
  defp text_for(:invalid_label_connection), do: "GitHub label data is unavailable."
  defp text_for(:invalid_lane), do: "Build lane label is invalid."
  defp text_for(:invalid_lifecycle), do: "GitHub issue lifecycle data is unavailable."
  defp text_for(:invalid_marker), do: "Planning marker is invalid."
  defp text_for(:invalid_member), do: "Member data is unavailable."
  defp text_for(:invalid_planning_bounds), do: "GitHub planning limits are invalid."
  defp text_for(:invalid_phase), do: "Phase label is invalid."
  defp text_for(:invalid_requested_root), do: "Requested Build Order root identity is invalid."
  defp text_for(:invalid_root), do: "Root data is unavailable."
  defp text_for(:invalid_title), do: "Title is unavailable."
  defp text_for(:invalid_url), do: "GitHub URL is unavailable."
  defp text_for(:incomplete_labels), do: "GitHub returned an incomplete label set."
  defp text_for(:labels_overflow), do: "Too many labels were supplied."
  defp text_for(:member_overflow), do: "Too many direct members were supplied."
  defp text_for(:missing_complexity), do: "Complexity label is missing."
  defp text_for(:missing_lane), do: "Build lane label is missing."
  defp text_for(:missing_phase), do: "Phase label is missing."
  defp text_for(:missing_root_label), do: "The selected root is not marked as a Build Order."
  defp text_for(:page_budget_exhausted), do: "The provider page budget was exhausted."
  defp text_for(:pagination_mismatch), do: "Provider pagination data is inconsistent."
  defp text_for(:provider_unavailable), do: "GitHub planning data is unavailable."
  defp text_for(:provider_schema), do: "GitHub returned an unexpected planning-data shape."
  defp text_for(:root_has_parent), do: "A Build Order root cannot have a parent."
  defp text_for(:unresolved_internal_dependency), do: "A configured-repository dependency is missing from this graph."
  defp text_for(:unsafe_external_url), do: "External dependency URL is unavailable."
  defp text_for(_code), do: "Build Order data is unavailable."
end
