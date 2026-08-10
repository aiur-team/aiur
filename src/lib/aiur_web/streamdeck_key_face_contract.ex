defmodule AiurWeb.StreamdeckKeyFaceContract do
  @moduledoc """
  Key-face labels and the queued footer's readiness wording, shared by the web
  emulator and `@aiur/streamdeck`.

  Scope is deliberately narrow: the bucket labels as both renderers draw them
  today, plus the queued footer's blocked/unblocked wording. State colours, the
  rank ordering, the progress hue mapping and the direction badges stay with
  their renderers until SP-305 (#1584) extracts them together with a
  cross-renderer contract test.

  `footer_for_agent/2` reads `:dependency_ready` with no default and compares it
  against `@ready_when` by strict equality, so an absent field, `nil`, or a
  stringy `"true"` all render `Blocked`. Readiness has to be stated, not assumed.
  """

  @labels %{
    alert: "Alert",
    stuck: "Stuck",
    running: "Running",
    paused: "Paused",
    queued: "Queued"
  }

  @ready_when true
  @ready_label "Unblocked"
  @blocked_label "Blocked"

  @type footer :: %{kind: String.t(), label: String.t(), dependency: String.t() | nil, ready?: boolean()}

  @spec label!(atom() | String.t()) :: String.t()
  def label!(bucket) when is_binary(bucket), do: label!(String.to_existing_atom(bucket))

  def label!(bucket) when is_atom(bucket) do
    case Map.fetch(@labels, bucket) do
      {:ok, label} -> label
      :error -> raise ArgumentError, "unhandled Stream Deck key state: #{inspect(bucket)}"
    end
  end

  @spec footer_for_agent(atom() | String.t(), map()) :: footer()
  def footer_for_agent(bucket, agent) when is_map(agent) do
    footer(bucket, Map.get(agent, :dependency_ready))
  end

  # Only queued keys carry dependency wording.
  defp footer(bucket, dependency_ready) do
    label = label!(bucket)

    if bucket in [:queued, "queued"] do
      ready? = dependency_ready === @ready_when
      dependency = if ready?, do: @ready_label, else: @blocked_label
      %{kind: "queued", label: label, dependency: dependency, ready?: ready?}
    else
      %{kind: "progress", label: label, dependency: nil, ready?: false}
    end
  end
end
