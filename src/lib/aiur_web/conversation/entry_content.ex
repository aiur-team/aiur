defmodule AiurWeb.Conversation.EntryContent do
  @moduledoc false
  use Phoenix.Component
  alias AiurWeb.Markdown

  attr(:entry, :map, required: true)
  @spec content(map()) :: Phoenix.LiveView.Rendered.t()
  def content(%{entry: %{role: "provider_input"}} = assigns) do
    ~H"""
    <p class="conversation-system">provider input: {@entry.body}</p>
    """
  end

  def content(%{entry: %{kind: "message"}} = assigns) do
    ~H"""
    <div class="conversation-markdown">{Markdown.render(@entry.body)}</div>
    """
  end

  def content(%{entry: %{kind: "reasoning"}} = assigns) do
    ~H"""
    <details class="conversation-reasoning"><summary>Reasoning</summary><div class="conversation-markdown">{Markdown.render(@entry.body)}</div></details>
    """
  end

  def content(%{entry: %{kind: "command"}} = assigns) do
    ~H"""
    <pre class="conversation-command">$ {@entry.body}</pre>
    <span :if={meta(@entry, :exit_code) not in [nil, 0]} class="conversation-failure">Exit {meta(@entry, :exit_code)}</span>
    <.output text={@entry.output} />
    """
  end

  def content(%{entry: %{kind: "tool_result"}} = assigns) do
    ~H"""
    <p>{meta(@entry, :tool) || "Tool"} · <span class={if meta(@entry, :success) == false, do: "conversation-failure"}>{success(meta(@entry, :success))}</span></p>
    <p :if={@entry.body != ""}>{@entry.body}</p>
    <.output text={@entry.output} />
    """
  end

  def content(%{entry: %{kind: "diff"}} = assigns) do
    assigns = assign(assigns, :lines, String.split(assigns.entry.output || "", "\n"))

    ~H"""
    <p class="conversation-file">{@entry.body}</p>
    <.diff_lines lines={Enum.take(@lines, 200)} />
    <details :if={length(@lines) > 200} class="conversation-diff-rest">
      <summary>{length(@lines) - 200} more diff lines</summary>
      <.diff_lines lines={Enum.drop(@lines, 200)} />
    </details>
    """
  end

  def content(%{entry: %{kind: "operator_message"}} = assigns) do
    ~H"""
    <div class="conversation-operator-bubble">
      <strong>{if @entry.role == "executor_operator", do: "Executor", else: "Operator"}</strong>
      <p>{@entry.body}</p>
    </div>
    """
  end

  def content(%{entry: %{kind: "system"}} = assigns) do
    ~H"""
    <p class={ ["conversation-system", meta(@entry, :alert) == true && "conversation-alert"] }>
      <strong :if={meta(@entry, :alert) == true}>Alert: </strong>{@entry.body}
    </p>
    """
  end

  def content(%{entry: %{kind: "gap"}} = assigns), do: gap(assigns)

  def content(assigns) do
    ~H"""
    <p class="conversation-unknown">Unknown entry kind: {@entry.kind}</p>
    <pre>{@entry.body}</pre><pre :if={@entry.output}>{@entry.output}</pre>
    """
  end

  attr(:entry, :map, required: true)
  @spec gap(map()) :: Phoenix.LiveView.Rendered.t()
  def gap(assigns) do
    ~H"""
    <div class="conversation-gap" role="note">
      No record from {meta(@entry, :from) || "unknown time"} to {meta(@entry, :to) || "unknown time"}
      · {gap_reason(meta(@entry, :reason))}
    </div>
    """
  end

  defp output(assigns) do
    ~H"""
    <details :if={@text not in [nil, ""]} class="conversation-output"><summary>Output</summary><pre>{@text}</pre></details>
    """
  end

  defp diff_lines(assigns) do
    ~H"""
    <pre class="conversation-diff"><code><span :for={line <- @lines} class={diff_class(line)}>{line}{"\n"}</span></code></pre>
    """
  end

  defp diff_class("+" <> _), do: "conversation-diff-add"
  defp diff_class("-" <> _), do: "conversation-diff-remove"
  defp diff_class("@@" <> _), do: "conversation-diff-hunk"
  defp diff_class(_), do: nil
  defp success(true), do: "Success"
  defp success(false), do: "Failed"
  defp success(_), do: "Status unknown"
  defp meta(entry, key), do: Map.get(entry.meta, key, Map.get(entry.meta, Atom.to_string(key)))

  @spec omitted_bytes(String.t() | nil) :: String.t()
  def omitted_bytes(text) do
    case Regex.run(~r/…\[(\d+) bytes omitted\]…/, text || "") do
      [_, bytes] -> bytes
      _ -> "unknown number of"
    end
  end

  @spec session_reason(String.t() | nil) :: String.t()
  def session_reason("resume"), do: "Resumed after restart"
  def session_reason("clear"), do: "New session after /clear"
  def session_reason("spawn"), do: "Worker started"
  def session_reason("start"), do: "Session started"
  def session_reason("import"), do: "Imported history"
  def session_reason(reason), do: reason || "Start reason unknown"
  defp gap_reason("pre_journal"), do: "Earlier history is not available"
  defp gap_reason("source_unreadable"), do: "Transcript source was unreadable"
  defp gap_reason("backpressure"), do: "Recording could not keep up"
  defp gap_reason(reason), do: reason || "Reason unknown"
end
