defmodule Aiur.Config.Schema.Decisions.NativeCapture do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @type t :: %__MODULE__{}

  embedded_schema do
    # @config-reference config-configuration-17 decisions.native_capture.codex
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail decisions.native_capture.codex | boolean | false | Capture native worker questions as Commands and hold their tool calls; enable the upstream under-development ask-user feature. Experimental; leave disabled until the native reply and release decision in #6424 is resolved (see also #4450). |
    field(:codex, :boolean, default: false)
    # @config-reference config-configuration-17 decisions.native_capture.claude
    # @config-detail decisions.native_capture.claude | boolean | false | Capture deferred Claude questions as Commands; requires aiur-claude >= 1.3.0. Older or unversioned siblings remain non-interactive. |
    field(:claude, :boolean, default: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:codex, :claude], empty_values: [])
    |> validate_required([:codex, :claude])
  end
end
