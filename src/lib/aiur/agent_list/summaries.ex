defmodule Aiur.AgentList.Summaries do
  @moduledoc """
  Pure transforms and predicates for AgentList summary rows.
  """

  @spec visible_summaries([map()]) :: [map()]
  def visible_summaries(summaries) do
    summaries
    |> Enum.reject(fn s ->
      tag = Map.get(s, :tag)
      tag in ["agent:cancelled", "agent:canceled", "agent:done"]
    end)
    |> Enum.sort_by(fn s ->
      # Group by live work state, then by numeric identifier ASCENDING
      # within each group. Previously
      # sorted identifiers as strings, so "10" came before "5" — the
      # user explicitly asked for natural numeric order within each
      # status-emoji bucket.
      emoji_bucket = emoji_sort_key(s)
      id_key = identifier_sort_key(Map.get(s, :identifier))
      {emoji_bucket, id_key}
    end)
  end

  @spec paused?(map()) :: boolean()
  def paused?(summary) do
    Map.get(summary, :work_state) in [:paused, "paused"]
  end

  @spec deactivated?(map()) :: boolean()
  def deactivated?(summary) do
    Map.get(summary, :work_state) in [:deactivated, "deactivated"]
  end

  @spec remote_control_on?(map()) :: boolean()
  def remote_control_on?(%{remote_control: %{status: status}})
      when status in [:launching, :on],
      do: true

  @spec remote_control_on?(map()) :: boolean()
  def remote_control_on?(_summary), do: false

  @spec active_agent_count([map()]) :: non_neg_integer()
  def active_agent_count(summaries) when is_list(summaries) do
    Enum.count(summaries, fn
      %{status: :running} = summary -> not paused?(summary)
      _ -> false
    end)
  end

  @spec id_sets([map()]) :: %{visible_ids: [term()], slot_ids: [term()], retain_ids: [term()]}
  def id_sets(summaries) do
    # Three derived sets:
    #
    # - `visible_ids` (every :running summary): drives per-id map
    #   compaction. `:deactivated` rows stay in the AgentList so their
    #   bar / latest / attention chips survive across the human-review
    #   transition.
    # - `slot_ids` (visible minus :paused minus :deactivated): the
    #   spawn-eligible set. Drives AttachPool seeding so a `:deactivated`
    #   row releases its warmed opencode pane and AttachPool reclaims the
    #   slot for newly-queued agents the user starts in its place.
    # - `retain_ids` (visible :paused, not :deactivated): the keep-pane
    #   set. A Ctrl+C pause holds the agent's opencode pane open until an
    #   explicit close (second Ctrl+C → :deactivated). Passing these to
    #   seed keeps their attachment instead of detaching on pause.
    %{
      visible_ids:
        summaries
        |> Enum.filter(fn s -> Map.get(s, :status) == :running end)
        |> Enum.map(&Map.get(&1, :identifier))
        |> Enum.reject(&is_nil/1),
      slot_ids:
        summaries
        |> Enum.filter(fn s ->
          Map.get(s, :status) == :running and
            not paused?(s) and
            not deactivated?(s)
        end)
        |> Enum.map(&Map.get(&1, :identifier))
        |> Enum.reject(&is_nil/1),
      retain_ids:
        summaries
        |> Enum.filter(fn s ->
          Map.get(s, :status) == :running and
            paused?(s) and
            not deactivated?(s)
        end)
        |> Enum.map(&Map.get(&1, :identifier))
        |> Enum.reject(&is_nil/1)
    }
  end

  # Map live work state to a stable sort bucket. Lower = higher in the
  # list. Warm readiness can change per identifier without reshuffling
  # rows, so ⏳ and 🟢 stay in the same working bucket.
  defp emoji_sort_key(%{status: :queued}), do: 4

  defp emoji_sort_key(%{status: :running} = summary) do
    case Map.get(summary, :work_state) do
      # 🟢 actively working — most useful to see first
      :working -> 0
      # ⏸️ paused — still alive, less urgent than working
      :paused -> 1
      # 💤 sleeping (idle stream-close) — still alive and mid-turn, just
      # quiet; sorts with :paused, above finished/errored rows.
      :sleeping -> 1
      # 🔴 error — surface above queued but below healthy
      :error -> 2
      # 🏁 deactivated (awaiting human review) — finished work, lives
      # at 100% green; same bucket as :error so 🏁 sits between active
      # work and the catch-all (a later iteration may sink 🏁 to the
      # bottom — see plan scope "Deferred for later").
      :deactivated -> 2
      _ -> 3
    end
  end

  defp emoji_sort_key(_), do: 5

  # Parse identifier as integer for natural numeric ordering. Falls
  # back to the original string for non-numeric identifiers (test
  # fixtures like "MT-FOCUS" or future namespaced ids) so they group
  # together rather than crash the sort.
  defp identifier_sort_key(nil), do: {1, ""}

  defp identifier_sort_key(identifier) when is_binary(identifier) do
    case Integer.parse(identifier) do
      {n, ""} -> {0, n}
      _ -> {1, identifier}
    end
  end

  defp identifier_sort_key(other), do: {1, to_string(other)}
end
