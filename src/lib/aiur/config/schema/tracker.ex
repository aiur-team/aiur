defmodule Aiur.Config.Schema.Github do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @max_planning_root_limit 100
  @max_planning_page_budget 4
  @max_planning_call_budget 4

  @primary_key false
  embedded_schema do
    field(:repo, :string)
    field(:label_prefix, :string, default: "agent")
    field(:bot_account, :string)
    field(:trusted_accounts, {:array, :string}, default: [])
    field(:allowed_users, {:array, :string}, default: [])
    field(:planning_root_limit, :integer, default: @max_planning_root_limit)
    field(:planning_page_budget, :integer, default: @max_planning_page_budget)
    field(:planning_call_budget, :integer, default: @max_planning_call_budget)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :repo,
        :label_prefix,
        :bot_account,
        :trusted_accounts,
        :allowed_users,
        :planning_root_limit,
        :planning_page_budget,
        :planning_call_budget
      ],
      empty_values: []
    )
    |> validate_required([:planning_root_limit, :planning_page_budget, :planning_call_budget])
    |> validate_change(:allowed_users, fn :allowed_users, users ->
      if Enum.all?(users, &(is_binary(&1) and String.trim(&1) != "")),
        do: [],
        else: [allowed_users: "must contain non-empty GitHub logins"]
    end)
    |> validate_number(:planning_root_limit,
      greater_than: 0,
      less_than_or_equal_to: @max_planning_root_limit
    )
    |> validate_number(:planning_page_budget,
      greater_than: 0,
      less_than_or_equal_to: @max_planning_page_budget
    )
    |> validate_number(:planning_call_budget,
      greater_than: 0,
      less_than_or_equal_to: @max_planning_call_budget
    )
  end
end

defmodule Aiur.Config.Schema.Linear do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:api_key, :string)
    field(:project_slug, :string)
    field(:endpoint, :string, default: "https://api.linear.app/graphql")
    field(:assignee, :string)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    cast(schema, attrs, [:api_key, :project_slug, :endpoint, :assignee], empty_values: [])
  end
end

defmodule Aiur.Config.Schema.Tracker do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Aiur.Config.Schema.{Github, Linear}

  @primary_key false

  embedded_schema do
    field(:kind, :string)
    field(:base_branch, :string)
    field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])

    field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])

    embeds_one(:github, Github, on_replace: :update, defaults_to_struct: true)
    embeds_one(:linear, Linear, on_replace: :update, defaults_to_struct: true)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:kind, :base_branch, :active_states, :terminal_states], empty_values: [])
    |> cast_embed(:github, with: &Github.changeset/2)
    |> cast_embed(:linear, with: &Linear.changeset/2)
  end
end
