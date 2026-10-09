defmodule Aiur.Config.Schema.MergePolicy do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  defmodule MainWatch do
    @moduledoc false

    use Ecto.Schema
    import Ecto.Changeset
    alias Aiur.Config.Schema.MergePolicy

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:workflows, {:array, :string}, default: [])
      field(:on_red, :string, default: "alert")
      field(:fixer_label, :string, default: "main-fix")
      field(:canary_minutes, :integer, default: 45)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :workflows, :on_red, :fixer_label, :canary_minutes], empty_values: [])
      |> validate_inclusion(:on_red, ["alert", "dispatch_fixer"], message: "must be one of: alert, dispatch_fixer")
      |> validate_format(:fixer_label, ~r/\S/, message: "must be a non-empty string")
      |> validate_change(:workflows, &MergePolicy.validate_string_list/2)
      |> validate_number(:canary_minutes, greater_than_or_equal_to: 0)
      |> validate_canary_minutes(attrs)
    end

    defp validate_canary_minutes(changeset, attrs) do
      case Map.get(attrs, "canary_minutes") do
        nil -> changeset
        value when is_integer(value) and value >= 0 -> changeset
        _ -> add_error(changeset, :canary_minutes, "must be a non-negative integer")
      end
    end
  end

  @primary_key false
  embedded_schema do
    field(:ci, :string, default: "wait")
    field(:local_tests, :string, default: "partial")
    field(:full_ci_labels, {:array, :string}, default: ["main-fix"])
    field(:full_ci_paths, {:array, :string}, default: [])
    field(:premerge_checks, {:array, :string}, default: [])
    field(:attribution_scan, :boolean, default: false)
    embeds_one(:main_watch, MainWatch, on_replace: :update, defaults_to_struct: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:ci, :local_tests, :full_ci_labels, :full_ci_paths, :premerge_checks, :attribution_scan], empty_values: [])
    |> validate_inclusion(:ci, ["wait", "pending_ok"], message: "must be one of: wait, pending_ok")
    |> validate_inclusion(:local_tests, ["all", "partial", "none"], message: "must be one of: all, partial, none")
    |> validate_change(:full_ci_labels, &validate_string_list/2)
    |> validate_change(:full_ci_paths, &validate_string_list/2)
    |> validate_change(:premerge_checks, &validate_string_list/2)
    |> cast_embed(:main_watch, with: &MainWatch.changeset/2)
    |> validate_pending_ci()
    |> validate_fixer_label()
  end

  @doc false
  @spec validate_string_list(atom(), list()) :: [{atom(), String.t()}]
  def validate_string_list(field, values) do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")),
      do: [],
      else: [{field, "must contain non-empty strings"}]
  end

  defp validate_pending_ci(changeset) do
    if get_field(changeset, :ci) == "pending_ok" do
      changeset
      |> require_main_watch()
      |> reject_no_local_tests()
    else
      changeset
    end
  end

  defp require_main_watch(changeset) do
    if get_field(changeset, :main_watch).enabled,
      do: changeset,
      else: add_error(changeset, :ci, "pending_ok requires merge_policy.main_watch.enabled to be true")
  end

  defp reject_no_local_tests(changeset) do
    if get_field(changeset, :local_tests) == "none",
      do: add_error(changeset, :local_tests, "must be all or partial when merge_policy.ci is pending_ok"),
      else: changeset
  end

  defp validate_fixer_label(changeset) do
    watch = get_field(changeset, :main_watch)
    labels = get_field(changeset, :full_ci_labels)

    if changeset.valid? and watch.on_red == "dispatch_fixer" and not Enum.any?(labels, &(String.downcase(&1) == String.downcase(watch.fixer_label))),
      do: add_error(changeset, :full_ci_labels, "must include merge_policy.main_watch.fixer_label when merge_policy.main_watch.on_red is dispatch_fixer"),
      else: changeset
  end
end
