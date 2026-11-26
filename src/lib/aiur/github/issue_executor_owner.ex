defmodule Aiur.GitHub.IssueExecutorOwner do
  @moduledoc false

  alias Aiur.GitHub.Labels

  @spec from_labels([String.t()], String.t()) :: String.t() | nil
  def from_labels(label_names, prefix) when is_list(label_names) do
    owner_prefix = prefix |> Labels.executor_label_prefix() |> normalize_label()
    bare_label = String.trim_trailing(owner_prefix, ":")

    Enum.find_value(label_names, &owner_from_label(&1, bare_label, owner_prefix))
  end

  defp owner_from_label(label, _bare_label, _owner_prefix) when not is_binary(label), do: nil

  defp owner_from_label(label, bare_label, owner_prefix) do
    normalized = normalize_label(label)

    case normalized do
      ^bare_label ->
        "unknown"

      _ ->
        owner = String.replace_prefix(normalized, owner_prefix, "")
        if owner != normalized and owner != "", do: owner
    end
  end

  defp normalize_label(label) when is_binary(label), do: String.downcase(String.trim(label))
  defp normalize_label(_label), do: ""
end
