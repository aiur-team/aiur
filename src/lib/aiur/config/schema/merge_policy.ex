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
      # @config-reference config-merge-policy-00 merge_policy.main_watch.enabled
      # @config-detail merge_policy.main_watch.enabled | boolean | false | Watches completed CI on the configured base branch through webhooks and polling. |
      field(:enabled, :boolean, default: false)
      # @config-reference config-merge-policy-00 merge_policy.main_watch.workflows
      # @config-detail merge_policy.main_watch.workflows | array | `[]` | Workflow names to watch; empty means every workflow on the base branch. |
      field(:workflows, {:array, :string}, default: [])
      # @config-reference config-merge-policy-00 merge_policy.main_watch.on_red
      # @config-detail merge_policy.main_watch.on_red | string | `alert` | `alert` reports failed CI; `dispatch_fixer` files a P1 fixer after confirmed red CI and dispatches it first. |
      field(:on_red, :string, default: "alert")
      # @config-reference config-merge-policy-00 merge_policy.main_watch.fixer_label
      # @config-detail merge_policy.main_watch.fixer_label | string | `main-fix` | Label for fixer tickets and their full-CI requirement. |
      field(:fixer_label, :string, default: "main-fix")
      # @config-reference config-merge-policy-00 merge_policy.main_watch.canary_minutes
      # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
      # @config-detail merge_policy.main_watch.canary_minutes | integer | 45 | Minutes without a completed watched run before rerunning the newest cancelled run; requires Actions write permission, otherwise raises attention. `0` disables. |
      field(:canary_minutes, :integer, default: 45)
      # @config-reference config-merge-policy-00 merge_policy.main_watch.red_fallback_minutes
      # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
      # @config-detail merge_policy.main_watch.red_fallback_minutes | integer | 0 | Optional full-CI wait after main stays red this many minutes; absent/`0` disables, `60` enables a one-hour threshold; the merge-policy consumer enforces the threshold using the watcher’s retained state. |
      field(:red_fallback_minutes, :integer, default: 0)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :workflows, :on_red, :fixer_label, :canary_minutes, :red_fallback_minutes], empty_values: [])
      |> validate_inclusion(:on_red, ["alert", "dispatch_fixer"], message: "must be one of: alert, dispatch_fixer")
      |> validate_format(:fixer_label, ~r/\S/, message: "must be a non-empty string")
      |> validate_change(:workflows, &MergePolicy.validate_string_list/2)
      |> validate_number(:canary_minutes, greater_than_or_equal_to: 0)
      |> validate_minutes(attrs, :canary_minutes)
      |> validate_number(:red_fallback_minutes, greater_than_or_equal_to: 0)
      |> validate_minutes(attrs, :red_fallback_minutes)
    end

    defp validate_minutes(changeset, attrs, field) do
      case Map.get(attrs, Atom.to_string(field)) do
        nil -> changeset
        value when is_integer(value) and value >= 0 -> changeset
        _ -> add_error(changeset, field, "must be a non-negative integer")
      end
    end
  end

  @primary_key false
  embedded_schema do
    # @config-reference config-merge-policy-00 merge_policy.ci
    # @config-detail merge_policy.ci | string | `wait` | `wait` (the only mode) requires full CI before merge. |
    field(:ci, :string, default: "wait")
    # @config-reference config-merge-policy-00 merge_policy.local_tests
    # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
    # @config-detail merge_policy.local_tests | string | `partial` | `all`: full local suite; `partial`: tests relevant to the change, falling back to the full suite when selection is unsafe; `none`: compile and format only. |
    field(:local_tests, :string, default: "partial")
    # @config-reference config-merge-policy-00 merge_policy.full_ci_labels
    # @config-detail merge_policy.full_ci_labels | array | `[main-fix]` | Case-insensitive PR or ticket labels requiring full CI regardless of `ci`. |
    field(:full_ci_labels, {:array, :string}, default: ["main-fix"])
    # @config-reference config-merge-policy-00 merge_policy.full_ci_paths
    # @config-detail merge_policy.full_ci_paths | array | `[]` | Changed-path globs (`*`, `**`, `?`) requiring full CI on approved PRs and the merge queue; matches deleted paths too. |
    field(:full_ci_paths, {:array, :string}, default: [])
    # @config-reference config-merge-policy-00 merge_policy.premerge_checks
    # @config-detail merge_policy.premerge_checks | array | `[]` | Commands to run on the merge result before merging. |
    field(:premerge_checks, {:array, :string}, default: [])
    # @config-reference config-merge-policy-00 merge_policy.attribution_scan
    # @config-detail merge_policy.attribution_scan | boolean | false | Enables the premerge AI-attribution scan of the PR title and body. |
    field(:attribution_scan, :boolean, default: false)
    embeds_one(:main_watch, MainWatch, on_replace: :update, defaults_to_struct: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:ci, :local_tests, :full_ci_labels, :full_ci_paths, :premerge_checks, :attribution_scan], empty_values: [])
    |> validate_inclusion(:ci, ["wait"], message: "must be one of: wait")
    |> validate_inclusion(:local_tests, ["all", "partial", "none"], message: "must be one of: all, partial, none")
    |> validate_change(:full_ci_labels, &validate_string_list/2)
    |> validate_change(:full_ci_paths, &validate_string_list/2)
    |> validate_change(:premerge_checks, &validate_string_list/2)
    |> cast_embed(:main_watch, with: &MainWatch.changeset/2)
    |> validate_fixer_label()
  end

  @doc false
  @spec validate_string_list(atom(), list()) :: [{atom(), String.t()}]
  def validate_string_list(field, values) do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")),
      do: [],
      else: [{field, "must contain non-empty strings"}]
  end

  defp validate_fixer_label(changeset) do
    watch = get_field(changeset, :main_watch)
    labels = get_field(changeset, :full_ci_labels)

    if changeset.valid? and watch.on_red == "dispatch_fixer" and not Enum.any?(labels, &(String.downcase(&1) == String.downcase(watch.fixer_label))),
      do: add_error(changeset, :full_ci_labels, "must include merge_policy.main_watch.fixer_label when merge_policy.main_watch.on_red is dispatch_fixer"),
      else: changeset
  end
end
