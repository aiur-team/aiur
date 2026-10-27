defmodule Aiur.Config.Schema.Decisions.NativeCapture do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @type t :: %__MODULE__{}

  embedded_schema do
    # @config-reference config-configuration-17 decisions.native_capture.codex
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail decisions.native_capture.codex | boolean | false | Capture native worker questions as Commands and hold their tool calls. Experimental; leave disabled until native reply and release support is deployed. |
    field(:codex, :boolean, default: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:codex], empty_values: [])
    |> validate_required([:codex])
  end
end
