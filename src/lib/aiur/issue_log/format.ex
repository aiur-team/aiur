defmodule Aiur.IssueLog.Format do
  @moduledoc false

  alias Aiur.AgentEvents
  alias Aiur.Events.Catalog

  @spec format_transcript(term(), term(), map()) :: String.t()
  def format_transcript(role, body, event) do
    ts = timestamp(event)
    body_text = body |> to_string() |> String.replace("\r\n", "\n")
    "#{ts} [#{transcript_tag(role, event)}] #{body_text}\n"
  end

  # An Executor message is echoed when it is queued, not when the agent gets
  # it. A `[user]` tag made a queued copy look delivered (#2717), so the echo
  # is tagged `queued` with its queue item and decision id. Provider delivery
  # is logged as its own line.
  defp transcript_tag(:user, %{payload: %{operator_message: %{status: :queued} = message}}) do
    ["queued", tag_field("item", Map.get(message, :request_id)), tag_field("decision", Map.get(message, :decision_id))]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp transcript_tag(role, _event), do: tag_for_role(role)

  defp tag_field(_name, nil), do: nil
  defp tag_field(name, value), do: "#{name}=#{value}"

  @spec format_alert(term(), term(), map()) :: String.t()
  def format_alert(name, message, event) do
    ts = timestamp(event)
    "#{ts} [alert] #{name}: #{message}\n"
  end

  @spec format_event_marker(atom(), map()) :: String.t()
  def format_event_marker(kind, event) do
    "#{event_timestamp(event)} [event:#{kind}] id=#{event_field(event, :id, "")}" <>
      event_segments(kind, event) <>
      " #{event_field(event, :topic, "")}" <>
      message_suffix(event) <>
      "\n"
  end

  defp event_timestamp(event) do
    case event_field(event, :observed_at, nil) do
      %DateTime{} = ts -> DateTime.to_iso8601(ts)
      _ -> timestamp(event)
    end
  end

  defp event_segments(:command, event), do: " cmd=#{Base.url_encode64(to_string(event_field(event, :message, "")), padding: false)}"

  defp event_segments(_kind, event) do
    progress =
      if String.ends_with?(event_field(event, :topic, ""), ".progress") or String.ends_with?(event_field(event, :topic, ""), ".progress.checkin"),
        do: append_flag([], "pct", event_field(event, :percent, nil)) |> Enum.join(" "),
        else: ""

    flag_segment(event) <> actor_segment(event) <> if(progress == "", do: "", else: " " <> progress) <> ci_checks_segment(event)
  end

  defp ci_checks_segment(event) do
    if String.ends_with?(event_field(event, :topic, ""), ".ci.failed") or
         String.ends_with?(event_field(event, :topic, ""), ".ci.merge_group.failed") do
      case safe_ci_checks(event_field(event, :checks, [])) do
        [] -> ""
        checks -> " ci=#{checks |> Jason.encode!() |> Base.url_encode64(padding: false)}"
      end
    else
      ""
    end
  end

  defp safe_ci_checks(checks) when is_list(checks) do
    checks
    |> Enum.take(30)
    |> Enum.flat_map(fn check ->
      name = check_field(check, :name)
      url = check_field(check, :url) || check_field(check, :html_url)
      name = if is_binary(name), do: name |> Aiur.SecretRedactor.redact() |> String.slice(0, 160), else: nil

      case {name, safe_check_url(url)} do
        {name, url} when is_binary(name) and name != "" -> [%{"name" => name, "url" => url}]
        _ -> []
      end
    end)
  end

  defp safe_ci_checks(_), do: []
  defp check_field(check, key) when is_map(check), do: Map.get(check, key) || Map.get(check, Atom.to_string(key))
  defp check_field(_check, _key), do: nil

  defp safe_check_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme == "https" and uri.host in ["github.com", "www.github.com"] and is_nil(uri.userinfo) and
         is_binary(uri.path) and String.contains?(uri.path, ["/actions/runs/", "/check-runs/"]) do
      URI.to_string(%{uri | query: nil, fragment: nil})
    end
  rescue
    _ -> nil
  end

  defp safe_check_url(_url), do: nil

  defp actor_segment(event) do
    topic = event_field(event, :topic, "")

    if Catalog.lookup(topic).attribution == :payload_actor do
      " actor=#{event_field(event, :actor, :unknown)}"
    else
      ""
    end
  end

  defp event_field(event, key, default) do
    Map.get(event, key) || Map.get(event, Atom.to_string(key)) || default
  end

  # `src=`/`trust=`/`digest=` are appended in a fixed order before the `topic`
  # so `Aiur.IssueLog.event_history/2` can reconstruct the security-
  # sensitive flags on bootstrap. Without them, U2 replays would
  # bypass the U7 CODEOWNERS filter and `<external-content>` wrapper.
  defp flag_segment(event) do
    flags =
      []
      |> append_flag("src", event_field(event, :source, nil))
      |> append_flag("trust", event_field(event, :author_trusted?, nil))
      |> append_flag("digest", event_field(event, :digest_source, nil))
      |> Enum.join(" ")

    if flags == "", do: "", else: " " <> flags
  end

  defp message_suffix(event) do
    msg = event_field(event, :message, "")
    if msg == "", do: "", else: ": " <> summarize(to_string(msg))
  end

  defp append_flag(acc, _name, nil), do: acc
  defp append_flag(acc, name, value), do: acc ++ ["#{name}=#{value}"]

  @spec format_log_line(term(), term(), term()) :: String.t()
  def format_log_line(role, body, identifier) do
    "[#{tag_for_role(role)}] (##{identifier}) #{summarize(body)}"
  end

  defp tag_for_role(role)
       when role in [:assistant, :user, :system, :command, :alert, :reasoning, :tool],
       do: AgentEvents.tag_name(role)

  defp tag_for_role(other), do: to_string(other)

  defp summarize(nil), do: ""

  defp summarize(text) when is_binary(text) do
    single_line = text |> String.replace(~r/\r?\n/, " ") |> String.trim()

    # Sliced by graphemes, not by bytes.
    #
    # `binary_part/3` cut mid-codepoint whenever the 200th byte landed inside a
    # multi-byte character — routine for a model-authored summary carrying an
    # emoji or CJK — and wrote invalid UTF-8 into the durable event log. That was
    # survivable while these summaries only ever became prompt text; now that
    # the Stream Deck reads the same rows and `Jason` encodes them onto the
    # channel, an invalid byte raises, kills the socket, and the sidecar
    # reconnects into the same durable line for as long as the log exists.
    if String.length(single_line) > 200 do
      String.slice(single_line, 0, 200) <> "…"
    else
      single_line
    end
  end

  defp summarize(other), do: inspect(other)

  defp timestamp(event) do
    case Map.get(event, :timestamp) do
      %DateTime{} = ts -> DateTime.to_iso8601(ts)
      _ -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end
end
