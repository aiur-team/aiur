defmodule Aiur.GitHub.AgentCacheBridge do
  @moduledoc """
  Carries `Aiur.GitHub.ResourceStore` changes into the agents' `gh` answer store
  (#2073 U6).

  ## Why a bridge and not one store

  The store is an ETS table with a JSON checkpoint, inside the BEAM. The agent
  `gh` wrapper is a POSIX shell script in another process, and the only things it
  can read without paying for an interpreter start are files. So the two halves
  cannot be one table; what they can be is one **identity**. Both address a
  resource as `{type, owner, repo, id}`, and `Aiur.GitHub.AgentCache.resource_dir/2`
  is the single function that turns that into the directory the wrapper reads.

  This process is what makes the identity worth having. Every store write
  publishes a change event, so a fact Aiur learned for free — a webhook delivery,
  a mutation's own response, a need-driven fetch — retires the agents' copies of
  that resource in the same moment. Without it an agent would keep replaying an
  answer the daemon already knows is stale until its freshness window closed.

  Note the direction. The bridge never copies a body across: a stored REST body
  is not the `gh` stdout an agent expects, and reconstructing one from the other
  would corrupt agent input silently (`Aiur.GitHub.AgentCache` explains why at
  length). It carries only "this resource moved", which is exactly the part both
  halves can agree on.

  ## Failing open

  A subscription that cannot be established, an unwritable marker directory, an
  event shape this process does not recognise: all of them leave the agents
  serving entries until their own windows close. That costs at most one stale
  window. It never costs a failed daemon operation and never blocks an agent.
  """

  use GenServer

  require Logger

  alias Aiur.GitHub.{AgentCache, ResourceEvents, ResourceStore}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    ResourceStore.subscribe_all()
    {:ok, %{opts: Keyword.take(opts, [:state_dir])}}
  end

  # A store write that moved only a conditional-request validator is not news
  # about a resource: nobody's cached answer is wrong because a poll re-recorded
  # an `ETag`. These endpoint identities publish on every sweep — the repo-wide
  # comment streams alone do it twice a dispatch tick — and treating each as a
  # change would retire every cached collection query in the repository several
  # times a minute, which is the sharing this exists for, undone.
  @validator_only [
    :issue_comments,
    :pr_issue_comments,
    :repo_issue_comment_stream,
    :repo_review_comment_stream,
    :pull_request_reviews,
    :labelled_pull_requests
  ]

  @impl GenServer
  def handle_info({:github_resource_changed, %{key: {type, _owner, _repo, _id}}}, state)
      when type in @validator_only do
    {:noreply, state}
  end

  def handle_info({:github_resource_changed, %{key: key}}, state) do
    AgentCache.invalidate_key(key, state.opts)
    {:noreply, state}
  end

  # A change event whose shape this process does not know. Ignored rather than
  # crashed on: the store is a cache and this is a cache of a cache, so the worst
  # an unrecognised event can be allowed to cost is a stale window.
  def handle_info({:github_resource_changed, _change}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec message() :: atom()
  def message, do: ResourceEvents.message()
end
