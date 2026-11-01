defmodule Aiur.Config.Schema.Decisions.NativeCapture do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @type t :: %__MODULE__{}

  embedded_schema do
    # @config-reference config-configuration-17 decisions.native_capture.codex
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail decisions.native_capture.codex | boolean | true | Capture native worker questions as Commands and hold their tool calls; enable the upstream under-development ask-user feature. Set false to opt out. |
    field(:codex, :boolean, default: true)
    # @config-reference config-configuration-17 decisions.native_capture.claude
    # @config-detail decisions.native_capture.claude | boolean | true | Capture deferred Claude questions as Commands; requires aiur-claude >= 1.1.1. Older or unversioned siblings remain non-interactive. |
    field(:claude, :boolean, default: true)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:codex, :claude], empty_values: [])
    |> validate_required([:codex, :claude])
  end
end
