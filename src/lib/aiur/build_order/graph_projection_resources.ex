defmodule Aiur.BuildOrder.GraphProjection.Resources do
  @moduledoc false

  # Store resource-change routing, repository match and the member-due debounce timers.
  # Runs inside the projection process: every `self()` here is the GenServer.

  alias Aiur.BuildOrder.CatalogStore
  alias Aiur.BuildOrder.GraphProjection.{Policy, Reads, Schedule}
  alias Aiur.TrackerIdentity

  @spec drop_member_due(map(), term()) :: map()
  def drop_member_due(member_due, key) do
    case Map.pop(member_due, key) do
      {nil, member_due} ->
        member_due

      {%{timer: timer}, member_due} ->
        Process.cancel_timer(timer)
        member_due
    end
  end

  # A store change to one of the catalog's inputs rebuilds the catalog from the
  # store. Only the active repository's changes count; another repo's events are
  # this projection's business about as much as another repo's issues.
  @spec on_resource_change(map(), term()) :: {map(), [tuple()]}
  def on_resource_change(state, %{resource_type: type} = change)
      when type in [:issue, :issue_labels, :sub_issue, :issue_dependency] do
    if repository_match?(state, change) do
      state = %{state | catalog_change_seq: state.catalog_change_seq + 1}
      {state, catalog_events} = Reads.request_scope(state, :catalog)
      {state, selected_events} = request_affected_selected(state, type, change)
      {state, catalog_events ++ selected_events}
    else
      {state, []}
    end
  end

  def on_resource_change(state, _change), do: {state, []}

  # A store change's `owner`/`repo` are the components of the resource key, so
  # both must match the active repository.
  @spec repository_match?(map(), term()) :: boolean()
  def repository_match?(%{active_repository: {owner, repo}}, %{owner: change_owner, repo: change_repo})
      when is_binary(change_owner) and is_binary(change_repo) do
    String.downcase(change_owner) == String.downcase(owner) and
      String.downcase(change_repo) == String.downcase(repo)
  end

  # A delivery-mode event names the repo as a full "owner/name" string.
  def repository_match?(%{active_repository: {owner, repo}}, delivered) when is_binary(delivered) do
    String.downcase(delivered) == String.downcase("#{owner}/#{repo}")
  end

  def repository_match?(_state, _other), do: false

  # A store change that the catalog's change marker cannot see re-reads the
  # watched roots it touches, after a short per-root debounce. Two kinds reach
  # here:
  #
  #   * a dependency edge (`:issue_dependency`), so a blocked-by relationship set
  #     outside Aiur reflects on the page (#2313). The edge's two ends are the
  #     blocked issue and the blocker; the affected roots are those the edge
  #     belongs to plus those whose member set includes either end;
  #   * a member's labels (`:issue_labels`), which the graph renders but the
  #     marker does not digest.
  #
  # A member's own `:issue` change deliberately buys nothing here. The only
  # part of an issue body the graph's progress depends on is its lifecycle
  # (`state`/`state_reason`), and that is exactly what the catalog's
  # `member_state_digest` hashes. The same store change rebuilds the catalog
  # (see `on_resource_change/2`), the rebuild moves the root's marker, and
  # `request_changed_selected_roots/2` buys the one read (#2608). Buying a second
  # read here as well was the double spend: this read was dispatched against
  # the old marker, so the rebuild's read could not coalesce onto it. And a
  # comment, a title or body edit, or an ETag rotation moves no lifecycle, so it
  # moves no marker and buys no read.
  defp request_affected_selected(state, :issue_dependency, %{id: id}) do
    case parse_edge_id(id) do
      {left, right} -> debounce_roots_containing(state, [left, right])
      _other -> {state, []}
    end
  end

  defp request_affected_selected(state, :issue_labels, %{id: id}) do
    case issue_number(id) do
      nil -> {state, []}
      number -> debounce_roots_containing(state, [number])
    end
  end

  defp request_affected_selected(state, _type, _change), do: {state, []}

  # Resolving the membership map means listing the store's sub-issue edges, so
  # it is bought only when some root is actually being watched. Every other
  # store change answers without touching the store.
  #
  # Nothing is read here. Each touched root is marked due after
  # `member_debounce_ms`; a root already marked stays on its first timer, so a
  # fleet relabelling forty tickets in a minute costs one read per root per
  # window, not one per label event.
  defp debounce_roots_containing(state, numbers) do
    if Enum.any?(state.selected, fn {_key, entry} -> Schedule.active_scope?(state, entry.scope) end) do
      members = CatalogStore.member_numbers(state.active_repository)

      state =
        state.selected
        |> Enum.filter(fn {_key, entry} -> Schedule.active_scope?(state, entry.scope) and selected_touches?(entry, numbers, members) end)
        |> Enum.reduce(state, fn {key, _entry}, state -> arm_member_due(state, key) end)

      {state, []}
    else
      {state, []}
    end
  end

  defp arm_member_due(state, key) do
    if Map.has_key?(state.member_due, key) do
      state
    else
      token = state.next_timer_token
      timer = Process.send_after(self(), {:graph_projection_member_due, key, token}, state.member_debounce_ms)

      %{state | member_due: Map.put(state.member_due, key, %{token: token, timer: timer}), next_timer_token: token + 1}
    end
  end

  # Any selected read dispatched after the change observes it, whatever asked
  # for it, so starting one spends the debounced request.
  @spec clear_member_due(map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}) :: map()
  def clear_member_due(state, {:selected, identity}) do
    key = Policy.root_key(identity)

    case Map.pop(state.member_due, key) do
      {nil, _member_due} ->
        state

      {%{timer: timer}, member_due} ->
        Process.cancel_timer(timer)
        %{state | member_due: member_due}
    end
  end

  def clear_member_due(state, _scope), do: state

  @spec cancel_member_due(map()) :: map()
  def cancel_member_due(state) do
    Enum.each(state.member_due, fn {_key, %{timer: timer}} -> Process.cancel_timer(timer) end)
    %{state | member_due: %{}}
  end

  # The debounce window has closed. A read still inflight was dispatched before
  # the change (starting one clears the mark), so it cannot answer it: wait for
  # it, then read. A root in failure backoff is left to its retry timer, which
  # re-reads it anyway.
  @spec request_member_due(map(), term()) :: {map(), [tuple()]}
  def request_member_due(state, key) do
    case Map.get(state.selected, key) do
      %{inflight: inflight} when not is_nil(inflight) ->
        {arm_member_due(state, key), []}

      %{scope: scope} = entry ->
        if Schedule.active_scope?(state, scope) and Schedule.retry_due?(entry, state),
          do: Reads.request_scope(state, scope),
          else: {state, []}

      _entry ->
        {state, []}
    end
  end

  defp issue_number(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} when number > 0 -> number
      _other -> nil
    end
  end

  defp issue_number(_id), do: nil

  defp parse_edge_id(id) when is_binary(id) do
    case String.split(id, ":") do
      [left, right] ->
        with {left, ""} <- Integer.parse(left),
             {right, ""} <- Integer.parse(right) do
          {left, right}
        else
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp parse_edge_id(_id), do: nil

  defp selected_touches?(%{scope: {:selected, identity}}, numbers, members) do
    root_number = identity_number(identity)

    if is_nil(root_number) do
      false
    else
      members_of_root = Map.get(members, root_number, [])
      Enum.any?(numbers, &(&1 == root_number or &1 in members_of_root))
    end
  end

  defp selected_touches?(_entry, _numbers, _members), do: false

  defp identity_number(%TrackerIdentity{identifier: identifier}) do
    case Integer.parse(identifier) do
      {number, ""} when number > 0 -> number
      _other -> nil
    end
  end

  defp identity_number(_identity), do: nil
end
