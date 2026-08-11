defmodule AiurWeb.OperatorControlCenter.UnitsTable do
  @moduledoc false

  use Phoenix.Component

  alias Aiur.BuildOrder.Bounded
  alias Aiur.CodingAgent
  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.{UnitsControlPolicy, UnitsPresentation, UnitsPresenter}

  attr(:view, :map, required: true)
  attr(:now, :any, required: true)
  attr(:controls, :map, default: %{})
  attr(:writable, :boolean, default: false)

  @spec units_table(map()) :: Phoenix.LiveView.Rendered.t()
  def units_table(assigns) do
    assigns =
      assigns
      |> assign(:rows, display_rows(assigns.view))
      |> assign(:status, Map.get(assigns.view, :status, :loading))
      |> assign(:message, Map.get(assigns.view, :message))

    ~H"""
    <div class="units-results" aria-describedby="units-filter-note">
      <div :if={@status == :loading} class="units-state empty-state">Loading Units…</div>

      <div :if={@status == :unavailable} class="units-state readonly-banner" role="status">
        <span aria-hidden="true">◉</span>
        <span><b>Units catalog unavailable.</b> {@message || "No last-known-good Units catalog is retained."}</span>
      </div>

      <div :if={@status == :unavailable} class="units-table-wrap">
        <table class="units-table">
          <caption class="sr-only">Units catalog</caption>
          <thead>
            <tr>
              <th class="ut-col-id">ID</th>
              <th class="ut-col-unit">Unit</th>
              <th class="ut-col-ticket">Ticket</th>
              <th class="ut-col-latest">Latest</th>
              <th class="ut-col-cmd">Command</th>
            </tr>
          </thead>
          <tbody>
            <tr class="units-row units-empty-row">
              <td class="units-empty-cell" colspan="5">No active agents</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@status == :empty} class="units-state empty-state">
        {@message || "No units have been observed in this run."}
      </div>

      <div :if={@status == :stale} class="units-state readonly-banner stale-banner" role="status">
        <span aria-hidden="true">◉</span>
        <span>
          <b>Stale Units catalog.</b>
          {@message || "Showing the last-known-good Units catalog while refresh is degraded."}
        </span>
      </div>

      <div :if={@view[:truncated?]} class="units-state readonly-banner" role="status">
        <span aria-hidden="true">◉</span>
        <span><b>Units catalog is partial.</b> Counts are lower bounds for the bounded membership prefix.</span>
      </div>

      <div :if={@view[:zero_result?]} class="units-state empty-state filtered-empty">
        <p>No units match this valid scope and condition selection.</p>
        <button type="button" class="btn ghost units-reset" phx-click="reset-units-filters">Reset Units filters</button>
      </div>

      <div :if={@rows != []} class="units-table-wrap">
        <table class="units-table">
          <caption class="sr-only">Units catalog with execution facts, current evidence, and named actions</caption>
          <thead>
            <tr>
              <th class="ut-col-id">ID</th>
              <th class="ut-col-unit">Unit</th>
              <th class="ut-col-ticket">Ticket</th>
              <th class="ut-col-latest">Latest</th>
              <th class="ut-col-cmd">Command</th>
            </tr>
          </thead>
          <tbody id="units-rows">
            <tr
              :for={{row, token, github_url} <- @rows}
              id={"unit-#{token}"}
              class={["units-row", row_tone(row)]}
              data-unit-token={token}
              data-github-url={github_url}
            >
              <td
                data-label="ID"
                class="ut-id-cell ut-open"
                phx-click="inspect-unit"
                phx-value-unit={token}
                data-ticket-context-origin
              >
                <span :if={row_tone(row)} class={["ut-alert", row_tone(row)]} aria-hidden="true">{icon(:warning)}</span>
                <span class="ut-id-num mono num">{id_number(row.identity)}</span>
              </td>

              <td data-label="Unit" class="ut-unit-cell ut-open" phx-click="inspect-unit" phx-value-unit={token}>
                <div class="ut-pill-row">
                  <span class={["u-pill", "u-agent", agent_class(agent_family(row))]} style={agent_style(agent_family(row))}>{agent_label(agent_family(row))}</span>
                  <span :if={is_integer(row.complexity)} class="u-pill u-cx">Cx:{row.complexity}</span>
                </div>
                <div class="ut-pill-row">
                  <span :if={present?(model_label(row))} class="u-pill u-model">{model_label(row)}</span>
                  <span class={["u-pill", "u-prio", priority_class(row)]}>{priority_label(row)}</span>
                </div>
              </td>

              <td data-label="Ticket" class="ut-ticket-cell ut-open" phx-click="inspect-unit" phx-value-unit={token}>
                <div class="ut-title">{known(row.title, "Title unknown")}</div>
                <span :if={present?(row.build_lane)} class={["u-lane", lane_class(row.build_lane)]}>
                  <span class="u-lane-dot" aria-hidden="true"></span>{String.upcase(row.build_lane)}
                </span>
                <span :if={!present?(row.build_lane) && present?(row.tracker_state)} class="u-lane is-state">
                  <span class="u-lane-dot" aria-hidden="true"></span>{row.tracker_state |> to_string() |> String.replace("-", " ") |> String.upcase()}
                </span>
              </td>

              <td data-label="Latest" class="ut-latest-cell ut-open" phx-click="inspect-unit" phx-value-unit={token}>
                <div class="ut-latest-head">
                  <span class="ut-latest-emoji" aria-hidden="true">{evidence_emoji(row)}</span>
                  <span class="ut-latest-text">{latest_text(row)}</span>
                </div>
                <span class="ut-pbar" aria-hidden="true"><i class={progress_tone(row)} style={"width:#{progress_width(row.progress)}%"}></i></span>
                <div class="ut-latest-meta mono num">
                  <span><span class="sr-only">Progress </span>{progress_pct(row.progress)}</span>
                  <span><span class="sr-only">Runtime </span>{runtime(row, @now)}</span>
                </div>
              </td>

              <td data-label="Command" class="ut-cmd-cell">
                <nav class="units-actions" aria-label={"Actions for #{identity_label(row.identity)}"}>
                  <.unit_control token={token} row={row} control={Map.get(@controls, token)} writable={@writable} />
                  <button
                    id={"units-conversation-#{token}"}
                    type="button"
                    class={["units-icon-action", !conversation_handle(row) && "unavailable"]}
                    phx-click={conversation_handle(row) && "read-conversation"}
                    phx-value-unit={token}
                    disabled={!conversation_handle(row)}
                    aria-disabled={to_string(!conversation_handle(row))}
                    aria-label={"Open chat for #{identity_label(row.identity)}"}
                    title={if(conversation_handle(row), do: "Open chat", else: "Chat unavailable")}
                  >{icon(:chat)}</button>
                  <a
                    :if={remote_control_url(row)}
                    class="units-icon-action"
                    href={remote_control_url(row)}
                    target="_blank"
                    rel="noopener noreferrer"
                    aria-label={"Open remote control for #{identity_label(row.identity)}"}
                    title="Remote control"
                  >{icon(:remote)}</a>
                </nav>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr(:token, :string, required: true)
  attr(:row, :map, required: true)
  attr(:control, :map, default: nil)
  attr(:writable, :boolean, default: false)

  defp unit_control(assigns) do
    affordance = UnitsControlPolicy.affordance(assigns.row, assigns.control)

    assigns =
      assigns
      |> assign(:affordance, affordance)
      |> assign(:identity_label, identity_label(assigns.row.identity))
      |> assign(:presentation, control_presentation(assigns.control))
      |> assign(:disabled?, control_button_disabled?(affordance, assigns.writable))

    ~H"""
    <div class="units-control" data-unit-control={@token}>
      <button
        :if={@affordance.state in [:enabled, :pending]}
        id={"units-control-#{@token}"}
        type="button"
        class={["units-icon-action", "units-control-action", control_tone_class(@affordance), @presentation && "tone-#{@presentation.tone}"]}
        phx-click="request-unit-control"
        phx-value-unit={@token}
        phx-value-action={control_action(@affordance)}
        disabled={@disabled?}
        aria-disabled={to_string(@disabled?)}
        aria-label={control_aria_label(@affordance, @identity_label)}
        title={control_button_label(@affordance)}
      >{control_icon(@affordance)}</button>

      <span
        :if={@affordance.state == :disabled}
        class="units-icon-action unavailable units-control-disabled"
        aria-disabled="true"
        title={UnitsControlPolicy.disabled_reason(@affordance.reason)}
        aria-label={control_disabled_label(@affordance.reason)}
      >{control_icon(@affordance)}</span>

      <span
        :if={@presentation}
        class="units-control-status sr-only"
        role="status"
        aria-live="polite"
        aria-atomic="true"
      >{@presentation.announce}</span>
    </div>
    """
  end

  # Icon-only control: pause bars, resume triangle, or a lock for disabled.
  defp control_icon(%{state: :disabled}), do: icon(:lock)
  defp control_icon(%{action: :resume}), do: icon(:resume)
  defp control_icon(%{pending_action: :resume}), do: icon(:resume)
  defp control_icon(_affordance), do: icon(:pause)

  @icon_svg ~s(viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true")

  defp icon(:pause),
    do: Phoenix.HTML.raw(~s(<svg #{@icon_svg}><rect x="7" y="5" width="3.5" height="14" rx="1"/><rect x="14" y="5" width="3.5" height="14" rx="1"/></svg>))

  defp icon(:resume), do: Phoenix.HTML.raw(~s(<svg #{@icon_svg}><path d="M7 5l12 7-12 7z"/></svg>))

  defp icon(:chat),
    do: Phoenix.HTML.raw(~s(<svg #{@icon_svg}><path d="M21 11.5a8.4 8.4 0 0 1-8.5 8.4 9 9 0 0 1-3.9-.9L3 20.5l1.5-4.4a8.4 8.4 0 0 1-1-4.1A8.4 8.4 0 0 1 12.5 3 8.4 8.4 0 0 1 21 11.5z"/></svg>))

  defp icon(:remote), do: Phoenix.HTML.raw(~s(<svg #{@icon_svg}><path d="M7 17 17 7M8 7h9v9"/></svg>))

  defp icon(:lock),
    do: Phoenix.HTML.raw(~s(<svg #{@icon_svg}><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>))

  defp icon(:warning),
    do: Phoenix.HTML.raw(~s(<svg #{@icon_svg}><path d="M12 3 2.8 20h18.4L12 3Z"/><path d="M12 9v4"/><path d="M12 17h.01"/></svg>))

  # Remote control deep-link, present only when the agent exposes one.
  defp remote_control_url(%{live_conversation: %{remote_control_url: url}}) when is_binary(url) and url != "", do: url
  defp remote_control_url(%{remote_control_url: url}) when is_binary(url) and url != "", do: url
  defp remote_control_url(_row), do: nil

  defp control_presentation(nil), do: nil
  defp control_presentation(control) when is_map(control), do: UnitsControlPolicy.presentation(control)

  defp control_button_disabled?(%{state: :enabled}, true), do: false
  defp control_button_disabled?(_affordance, _writable), do: true

  defp control_action(%{action: action}) when action in [:pause, :resume], do: Atom.to_string(action)
  defp control_action(%{pending_action: action}) when action in [:pause, :resume], do: Atom.to_string(action)
  defp control_action(_affordance), do: nil

  defp control_button_label(%{state: :pending, pending_action: action}), do: "#{control_verb(action)}…"
  defp control_button_label(%{action: action}), do: control_verb(action)

  defp control_verb(:pause), do: "Pause"
  defp control_verb(:resume), do: "Resume"
  defp control_verb(_action), do: "Control"

  defp control_disabled_label(:no_identity), do: "Control unavailable"
  defp control_disabled_label(:remote_control), do: "Remote Control"
  defp control_disabled_label(:replaced_generation), do: "Superseded"
  defp control_disabled_label(_reason), do: "Control unavailable"

  defp control_aria_label(%{state: :pending, pending_action: action}, identity),
    do: "#{control_verb(action)} #{identity} — request pending"

  defp control_aria_label(%{action: action}, identity), do: "#{control_verb(action)} #{identity}"

  defp control_tone_class(%{state: :pending}), do: "is-pending"
  defp control_tone_class(%{action: :resume}), do: "is-resume"
  defp control_tone_class(_affordance), do: "is-pause"

  defp known_percent(%{status: :known, percent: percent}) when is_integer(percent) and percent in 0..100, do: percent
  defp known_percent(_progress), do: nil

  defp identity_label(%TrackerIdentity{owner: owner, repository: repository, identifier: identifier})
       when is_binary(owner) and is_binary(repository) and is_binary(identifier),
       do: "#{owner}/#{repository} ##{identifier}"

  defp identity_label(_identity), do: "Typed identity unavailable"

  defp conversation_handle(%{live_conversation: %{generation_handle: handle}}) when is_binary(handle), do: handle
  defp conversation_handle(_row), do: nil

  defp runtime(row, now), do: UnitsPresentation.runtime_label(row, now)

  defp row_tone(%{reasons: %{blocking: blocking}}) when not is_nil(blocking), do: "is-blocked"
  defp row_tone(%{reasons: %{alert: alert}}) when not is_nil(alert), do: "has-alert"
  defp row_tone(_row), do: nil

  defp display_rows(view) do
    view
    |> Map.get(:rows, [])
    |> Enum.map(fn row -> {row, UnitsPresenter.row_token(row), trusted_url(row)} end)
  end

  defp trusted_url(%{url: url, identity: %TrackerIdentity{} = identity}) do
    case Bounded.github_issue_url_for(url, identity) do
      {:ok, trusted_url} -> trusted_url
      :error -> nil
    end
  end

  defp trusted_url(_row), do: nil
  # --- compact-row helpers ---------------------------------------------------

  defp id_number(%TrackerIdentity{identifier: identifier}) when is_binary(identifier) and identifier != "", do: identifier
  defp id_number(_identity), do: "—"

  defp agent_label(family), do: UnitsPresentation.agent_label(family)

  # A row names its provider family via `:agent_family` (metering) or `:backend`
  # (control), preferring the former. Both are matched against the registry's
  # provider families rather than a hardcoded `[:claude, :codex]`, so a new
  # backend's rows classify with no edit here.
  defp agent_family(row), do: UnitsPresentation.agent_family(row)

  defp agent_class(family) do
    case CodingAgent.provider_descriptor(family) do
      %{css_class: class} -> class
      _ -> "is-generic"
    end
  end

  defp agent_style(family) do
    case CodingAgent.provider_descriptor(family) do
      %{unit_color: color, unit_border: border, unit_background: background} ->
        "--provider-unit-color: #{color}; --provider-unit-border: #{border}; --provider-unit-background: #{background}"

      _ ->
        nil
    end
  end

  defp model_label(row), do: UnitsPresentation.model_label(row)
  defp priority_label(row), do: row |> UnitsPresentation.priority() |> elem(0)
  defp priority_class(row), do: row |> UnitsPresentation.priority() |> elem(1)

  defp lane_class(lane) when is_binary(lane) and lane != "", do: "is-lane-#{lane}"
  defp lane_class(_lane), do: nil

  defp evidence_emoji(%{latest_evidence: %{status: :known, source: %{kind: kind}}}), do: evidence_kind_emoji(kind)
  defp evidence_emoji(_row), do: "•"

  defp evidence_kind_emoji(:commit), do: "🔨"
  defp evidence_kind_emoji(:pull_request), do: "🔀"
  defp evidence_kind_emoji(:branch), do: "🌿"
  defp evidence_kind_emoji(:log), do: "📋"
  defp evidence_kind_emoji(:queue), do: "⏳"
  defp evidence_kind_emoji(_kind), do: "•"

  defp latest_text(row), do: UnitsPresentation.latest_text(row)

  defp progress_width(progress), do: known_percent(progress) || 0

  defp progress_pct(progress) do
    case known_percent(progress) do
      nil -> "—"
      percent -> "#{percent}%"
    end
  end

  defp progress_tone(%{reasons: %{blocking: blocking}}) when not is_nil(blocking), do: "is-blocked"
  defp progress_tone(%{reasons: %{alert: alert}}) when not is_nil(alert), do: "has-alert"
  defp progress_tone(_row), do: nil

  defp present?(value), do: not is_nil(value) and value != ""
  defp known(value, fallback)
  defp known(value, _fallback) when is_binary(value) and value != "", do: value
  defp known(_value, fallback), do: fallback
end
