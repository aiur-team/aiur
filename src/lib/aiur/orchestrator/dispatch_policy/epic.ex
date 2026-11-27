defmodule Aiur.Orchestrator.DispatchPolicy.Epic do
  @moduledoc false

  alias Aiur.Config
  alias Aiur.Issue

  @spec issue?(Issue.t()) :: boolean()
  def issue?(%Issue{build_order_role: :epic}), do: true
  def issue?(%Issue{sub_issues: issues}) when is_list(issues) and issues != [], do: true

  def issue?(%Issue{id: id, labels: labels}) when is_binary(id) and is_list(labels) do
    epic_label = configured_epic_label()

    has_epic_label =
      Enum.any?(labels, fn label ->
        normalized = String.downcase(String.trim(label))
        normalized == "epic" or String.starts_with?(normalized, "epic:") or normalized == epic_label
      end)

    has_epic_label
  end

  def issue?(_issue), do: false

  defp configured_epic_label do
    case Config.settings() do
      {:ok, _settings} -> String.downcase(Aiur.GitHub.Config.label_prefix() <> ":epic")
      _ -> "epic"
    end
  rescue
    _ -> "epic"
  end
end
