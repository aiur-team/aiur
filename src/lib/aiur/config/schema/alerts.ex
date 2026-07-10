defmodule Aiur.Config.Schema.Alerts do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    # `enabled` defaults true so machines already using `alerts.yaml` +
    # `~/alerts/*.wav` keep playing without an `alerts:` section (the OS-default
    # cross-platform set is the opt-in piece, gated by `use_os_default_sounds`).
    field(:enabled, :boolean, default: true)
    # false → topic→sound mapping from the alerts file (existing behaviour);
    # true → built-in macOS/Linux system sounds keyed by alert category.
    field(:use_os_default_sounds, :boolean, default: false)
    # Optional folder of custom sound files. In mapping mode it resolves bare
    # filenames; in OS-default mode a `<category>.<ext>` file here wins over the
    # OS sound.
    field(:sound_dir, :string)
    # Optional topic→sound map. `aiur init` scaffolds `.aiur/alerts` and points
    # here with `alerts_file: alerts` (a relative value resolves next to the
    # config dir; see `Aiur.Workflow`). Absolute / `~/` paths are honoured
    # as-is. When unset or missing, the bundled repo `alerts.yaml` is used.
    field(:alerts_file, :string)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    cast(schema, attrs, [:enabled, :use_os_default_sounds, :sound_dir, :alerts_file], empty_values: [])
  end
end
