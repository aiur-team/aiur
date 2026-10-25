defmodule Aiur.AgentRunner.ReworkFindings do
  @moduledoc """
  The review findings a rework turn must answer (#4654).

  Findings come from the numbered items in the latest blocking review body, the
  shape Executor reviews use. Each finding keeps the number the reviewer gave it,
  so the worker answers `1`, `2`, ... exactly as the review reads. An item that
  names no `file:line` (a body or test ask) is still a finding (#5746); numbered
  lines inside code fences are not.
  """

  alias Aiur.{Orchestrator.ReworkGate, Tracker}

  @type finding :: %{id: String.t(), file: String.t() | nil, line: String.t() | nil, ask: String.t()}

  @item ~r/^\s*(\d+)[.)]\s+(.+)$/
  @location ~r/([A-Za-z0-9_.\/-]+\.[A-Za-z0-9]+):~?(\d+)/
  @non_blocking_comment ~r/\b(?:no (?:blockers|blocking (?:findings|issues))|all blockers (?:addressed|resolved))\b/i
  @blocking_comment ~r/^(?:\s*\#{1,6})?\s*(?:blocking(?: findings| issues)?|blockers?|must fix|changes required)\s*:/im
  @pre_merge_request ~r/\b(?:update|rebase|merge|fix)\b[^\n.!?]*\bbefore merge\b/i

  @doc "Parses the numbered items of a review body, with the first `file:line` each names."
  @spec parse(term()) :: [finding()]
  def parse(body) when is_binary(body) do
    {findings, _in_fence?} =
      body
      |> String.split("\n")
      |> Enum.flat_map_reduce(false, fn line, in_fence? ->
        cond do
          String.starts_with?(String.trim_leading(line), "```") -> {[], not in_fence?}
          in_fence? -> {[], true}
          true -> {item(line), false}
        end
      end)

    findings
  end

  def parse(_body), do: []

  defp item(line) do
    case Regex.run(@item, line) do
      [_, id, text] ->
        {file, line_no} = text_location(text)
        [%{id: id, file: file, line: line_no, ask: ask(text)}]

      nil ->
        []
    end
  end

  defp text_location(text) do
    case Regex.run(@location, text) do
      [_, file, line_no] -> {file, line_no}
      _ -> {nil, nil}
    end
  end

  @doc "Returns the PR number and head, the latest blocking review's commit and time, and that review's parsed findings."
  @spec fetch(String.t(), keyword()) ::
          {:ok, %{number: term(), head: String.t() | nil, review_head: String.t() | nil, review_at: String.t() | nil, findings: [finding()]}}
          | {:error, term()}
  def fetch(identifier, opts \\ []) do
    fetch_reviews = Keyword.get(opts, :reviews_fetcher, &default_reviews/1)

    with {:ok, pr} <- ReworkGate.open_pr(identifier, opts),
         {:ok, reviews} <- fetch_reviews.(pr["number"]) do
      review = reviews |> ReworkGate.blocking_reviews() |> Enum.max_by(&{&1["submitted_at"], &1["id"]}, fn -> %{} end)
      {:ok, %{number: pr["number"], head: ReworkGate.head_sha(pr), review_head: review["commit_id"], review_at: review["submitted_at"], findings: parse(review["body"])}}
    else
      {:skip, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The branch's own commits and changed files from `review_head` to `head`.

  First-parent, non-merge commits only, so merging the base changes nothing.
  When the workspace cannot answer (a remote worker host, a missing object),
  only a moved head counts as a commit and the commit and file checks are skipped.
  """
  @spec branch_changes(Path.t() | nil, String.t(), String.t() | nil) :: {[String.t()] | :unknown, [String.t()] | :unknown}
  def branch_changes(_workspace, review_head, head) when head in [nil, review_head], do: {[], :unknown}

  def branch_changes(workspace, review_head, head) do
    log = ["log", "--first-parent", "--no-merges", "#{review_head}..#{head}"]

    with true <- is_binary(workspace) and File.dir?(workspace),
         {commits, 0} <- System.cmd("git", ["-C", workspace | log] ++ ["--format=%H"], stderr_to_stdout: true),
         {files, 0} <- System.cmd("git", ["-C", workspace | log] ++ ["--format=", "--name-only"], stderr_to_stdout: true) do
      {String.split(commits), files |> String.split("\n", trim: true) |> Enum.uniq()}
    else
      _unreadable -> {:unknown, :unknown}
    end
  end

  @doc """
  Whether the PR body was edited after the review (#4944).

  A review whose only blocker is the PR body is fixed by an edit, not a commit.
  An unreadable edit time counts as no edit, so the no-commit refusal stands.
  """
  @spec body_edited_since?(term(), String.t() | nil, keyword()) :: boolean()
  def body_edited_since?(number, review_at, opts \\ []) do
    fetch_edit = Keyword.get(opts, :body_edit_fetcher, &default_body_edit/1)

    with true <- is_integer(number) and is_binary(review_at),
         {:ok, edited_at} when is_binary(edited_at) <- fetch_edit.(number),
         {:ok, edited, _offset} <- DateTime.from_iso8601(edited_at),
         {:ok, reviewed, _offset} <- DateTime.from_iso8601(review_at) do
      DateTime.after?(edited, reviewed)
    else
      _no_edit -> false
    end
  end

  @doc "Returns the newest trusted PR conversation comment newer than the formal review."
  @spec latest_feedback_comment(term(), String.t() | nil, keyword()) :: {:ok, map() | nil} | {:error, term()}
  def latest_feedback_comment(number, review_at, opts \\ []) do
    fetch_comments = Keyword.get(opts, :pr_issue_comments_fetcher, &default_pr_issue_comments/1)

    case fetch_comments.(number) do
      {:ok, comments} when is_list(comments) ->
        latest =
          comments
          |> Enum.filter(&trusted_comment?(&1, review_at))
          |> Enum.max_by(&comment_timestamp/1, fn -> nil end)

        {:ok, latest}

      {:error, reason} ->
        {:error, reason}

      _invalid_response ->
        {:error, :invalid_comment_response}
    end
  end

  @doc "Checks whether a first-parent, non-merge commit was made after a blocking PR comment."
  @spec commit_after_comment?(Path.t() | nil, String.t() | nil, String.t() | nil) :: boolean()
  def commit_after_comment?(workspace, head, commented_at) do
    with true <- is_binary(workspace) and File.dir?(workspace) and is_binary(head) and is_binary(commented_at),
         {:ok, commented, _offset} <- DateTime.from_iso8601(commented_at),
         {output, 0} <- System.cmd("git", ["-C", workspace, "log", "--first-parent", "--no-merges", "--format=%cI", "-1", head], stderr_to_stdout: true),
         [committed_at | _] <- String.split(output, "\n", trim: true),
         {:ok, committed, _offset} <- DateTime.from_iso8601(committed_at) do
      DateTime.after?(committed, commented)
    else
      _unavailable -> false
    end
  end

  defp trusted_comment?(comment, review_at) when is_map(comment) do
    timestamp = comment_timestamp(comment)

    Map.get(comment, :authoritative) == true and is_binary(timestamp) and newer_than_review?(timestamp, review_at)
  end

  defp trusted_comment?(_comment, _review_at), do: false

  @doc "Whether a trusted PR conversation comment asks for a change."
  @spec change_request_comment?(term()) :: boolean()
  def change_request_comment?(body) do
    blocking_comment?(body) or
      (is_binary(body) and String.match?(body, ~r/\b(?:failing|failed) tests?\b|\btests? (?:are )?(?:failing|failed)\b/i))
  end

  defp blocking_comment?(body) when is_binary(body) do
    body = String.trim(body)
    not String.match?(body, @non_blocking_comment) and (String.match?(body, @blocking_comment) or String.match?(body, @pre_merge_request))
  end

  defp blocking_comment?(_body), do: false

  defp newer_than_review?(_timestamp, nil), do: true

  defp newer_than_review?(timestamp, review_at) do
    with {:ok, comment, _offset} <- DateTime.from_iso8601(timestamp),
         {:ok, review, _offset} <- DateTime.from_iso8601(review_at) do
      DateTime.after?(comment, review)
    else
      _invalid_timestamp -> false
    end
  end

  defp comment_timestamp(comment),
    do: Map.get(comment, "updated_at") || Map.get(comment, :updated_at) || Map.get(comment, "created_at") || Map.get(comment, :created_at)

  defp default_pr_issue_comments(number), do: Tracker.fetch_classified_issue_comments(number)

  defp default_body_edit(number), do: if(ReworkGate.available?(), do: Aiur.CodeHost.pull_request_body_edited_at(number), else: {:ok, nil})

  defp default_reviews(number) when is_integer(number) do
    if ReworkGate.available?(), do: Aiur.CodeHost.fetch_classified_pr_reviews(number), else: {:ok, []}
  end

  defp default_reviews(_number), do: {:ok, []}

  @doc "Renders the findings as the rework prompt's checklist; empty when there are none."
  @spec prompt_section([finding()]) :: String.t()
  def prompt_section([]), do: ""

  def prompt_section(findings) do
    """

    Review findings checklist (#4654): answer every item when you call `aiur_set_ticket_state` to hand back, in its `review_findings` argument.
    Mark each `fixed` with the commit that changes the named file, or `disputed` with concrete evidence. An item that names no file (a PR body or test ask) is `fixed` by a commit since the review or a PR body edit after it. The handback is refused while any item is unanswered, a `fixed` commit is not on the branch since the review, or its file was not changed since the review.
    #{Enum.map_join(findings, "\n", &"- #{&1.id}. #{location(&1)}#{&1.ask}")}
    """
  end

  @doc """
  Checks the worker's answers against the findings and the commits since the review.

  `commits` and `files` come from the branch's own (first-parent, non-merge)
  commits since the review, so merging the base touches nothing. `:unknown`
  skips the commit and file checks when the workspace cannot be read.
  `body_edited?` lifts only the no-commit refusal: a finding marked `fixed`
  still needs its own commit.
  """
  @spec validate([finding()], term(), [String.t()] | :unknown, [String.t()] | :unknown, boolean()) :: :allow | {:blocked, [String.t()]}
  def validate(findings, answers, commits, files, body_edited? \\ false) do
    answers = if is_list(answers), do: Enum.filter(answers, &is_map/1), else: []
    by_id = Map.new(answers, &{to_string(field(&1, "id")), &1})

    reasons =
      Enum.flat_map(findings, &finding_reasons(&1, Map.get(by_id, &1.id), commits, files, body_edited?)) ++
        if(body_edited?, do: [], else: no_commit_reason(findings, by_id, commits))

    if reasons == [], do: :allow, else: {:blocked, reasons}
  end

  defp finding_reasons(finding, nil, _commits, _files, _body_edited?), do: ["finding #{label(finding)} is unchecked: #{finding.ask}"]

  defp finding_reasons(finding, answer, commits, files, body_edited?) do
    case field(answer, "status") do
      "disputed" -> if blank?(field(answer, "evidence")), do: ["finding #{label(finding)} is disputed without evidence"], else: []
      "fixed" -> fixed_reasons(finding, field(answer, "commit"), commits, files, body_edited?)
      _other -> ["finding #{label(finding)} must be marked fixed or disputed"]
    end
  end

  defp fixed_reasons(_finding, _commit, :unknown, _files, _body_edited?), do: []

  # A finding that names no file can be a PR body ask, so a body edit after the review fixes it.
  defp fixed_reasons(%{file: nil}, commit, _commits, _files, true) when commit in [nil, ""], do: []

  defp fixed_reasons(finding, commit, commits, files, _body_edited?) do
    commit_reason =
      if is_binary(commit) and String.length(commit) >= 7 and Enum.any?(commits, &String.starts_with?(&1, commit)),
        do: [],
        else: ["finding #{label(finding)} is marked fixed by #{inspect(commit)}, which is not a commit since the review"]

    file_reason =
      if files == :unknown or is_nil(finding.file) or Enum.any?(files, &same_file?(&1, finding.file)),
        do: [],
        else: ["finding #{label(finding)} is marked fixed but #{finding.file} was not changed since the review"]

    commit_reason ++ file_reason
  end

  # Disputing every finding is a legitimate handback without a new commit; anything else needs one or a body edit.
  defp no_commit_reason(findings, by_id, []) do
    all_disputed? = findings != [] and Enum.all?(findings, &(field(Map.get(by_id, &1.id, %{}), "status") == "disputed"))
    if all_disputed?, do: [], else: ["no new commits or PR body edit since the review"]
  end

  defp no_commit_reason(_findings, _by_id, _commits), do: []

  @doc "The ticket comment that carries the worker's answers to the re-review."
  @spec comment_body([finding()], [map()]) :: String.t()
  def comment_body(findings, answers) do
    by_id = Map.new(answers, &{to_string(field(&1, "id")), &1})

    rows =
      Enum.map_join(findings, "\n", fn finding ->
        answer = Map.get(by_id, finding.id, %{})

        detail =
          cond do
            field(answer, "status") != "fixed" -> field(answer, "evidence")
            blank?(field(answer, "commit")) -> "PR body edited after the review"
            true -> "commit `#{field(answer, "commit")}`"
          end

        "- [x] #{finding.id}. #{location(finding)}#{finding.ask}\n  **#{field(answer, "status")}**: #{detail}"
      end)

    "## Rework checklist\n\nThe worker's answers to the latest review's findings, verified before this handback.\n\n" <> rows <> "\n"
  end

  # Reviews name a file by basename or without `src/`; the branch lists repo-relative paths.
  defp same_file?(changed, file), do: changed == file or String.ends_with?(changed, "/" <> file)

  defp label(%{file: nil} = finding), do: finding.id
  defp label(finding), do: "#{finding.id} (#{finding.file}:#{finding.line})"

  defp location(%{file: nil}), do: ""
  defp location(finding), do: "`#{finding.file}:#{finding.line}` — "

  defp ask(text) do
    text = String.trim(text)
    if String.length(text) > 200, do: String.slice(text, 0, 197) <> "...", else: text
  end

  # Tool arguments arrive as decoded JSON, so keys are strings.
  defp field(map, key), do: Map.get(map, key)

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
