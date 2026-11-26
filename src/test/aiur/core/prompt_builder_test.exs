defmodule Aiur.Core.PromptBuilderTest do
  use Aiur.TestSupport

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"],
      creator_login: "outsider"
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    # SECURITY INVARIANT — the title still reaches the prompt, but never as bare
    # prompt text. Anyone can open an issue on a public repo, so `{{ issue.title }}`
    # renders sanitized and inside `<external-content>`, which is what tells the
    # agent the words are data and not instructions Aiur wrote. Assert the whole
    # wrapper: a substring match on the title alone would still pass if the
    # wrapping were removed.
    assert prompt =~
             ~s(Ticket S-1 <external-content source="github" author="outsider">Refactor backend request path</external-content>)

    # Aiur-derived / GitHub-structural fields stay unwrapped so the agent can
    # still tell task metadata from outsider prose.
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes invalid rendered bytes to utf8" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.title }}")

    issue = %Issue{
      identifier: "MT-698",
      title: <<255>>,
      description: "Prompt should not return invalid bytes",
      state: "Todo",
      url: "https://example.org/issues/MT-698",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert String.valid?(prompt)
    refute prompt == <<"Ticket ", 255>>
  end

  test "prompt builder prepends shared agent instructions" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-699",
      title: "Use shared prompt instructions",
      description: "Prompt should include repo-wide guidance",
      state: "Todo",
      url: "https://example.org/issues/MT-699",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    # The shared prefix is slimmed to the always-visible / between-turn
    # reflexes plus a pointer to the `aiur-agent` operating-manual skill.
    assert prompt =~ "## Shared Agent Instructions"
    assert prompt =~ "aiur-agent"
    assert prompt =~ "Progress emits"
    assert prompt =~ "Executor check-ins"

    # The general operating manual (complexity routing, CODEOWNERS authority,
    # PR shape, milestone-alert names, the dev loop) now lives only in the
    # `aiur-agent` skill — it is no longer inlined into every per-turn prompt.
    refute prompt =~ "### Complexity routing"
    refute prompt =~ "#### `complexity:"
    refute prompt =~ "label-based complexity is the default"
    refute prompt =~ "### PR description shape"
    refute prompt =~ "### Whose comments to act on"
    refute prompt =~ "use CODEOWNERS as the authority signal"
    refute prompt =~ "brainstorm.start"

    assert prompt =~ "Ticket MT-699"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    # `PromptBuilder` prepends shared-agent-instructions; assert on
    # the rendered tail rather than equality.
    assert String.ends_with?(PromptBuilder.build_prompt(issue), "Ticket MT-701")
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Body:"

    # SECURITY INVARIANT — the built-in fallback template is not a way around the
    # wrapper. Title and body are attacker-controlled on a public repo, so they
    # are sanitized and wrapped in `<external-content>` by the builder (not by
    # the template) on every path, including this one. `creator_login` is nil
    # here, which is the no-`author`-attribute form of the tag. Assert the whole
    # wrapper rather than the prose alone, so dropping the wrapping fails.
    assert prompt =~ ~s(Title: <external-content source="github">Make fallback prompt useful</external-content>)

    assert prompt =~
             ~s(<external-content source="github">Include enough issue context to start working.</external-content>)

    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"

    # SECURITY INVARIANT — see the fallback-template test above: the title is
    # attacker-controlled, so it renders sanitized inside `<external-content>`.
    assert prompt =~ ~s(Title: <external-content source="github">Handle empty body</external-content>)

    # A nil description must stay nil through the wrapper, so the template's
    # `{% if issue.description %}` branch still picks the placeholder. An empty
    # wrapper here would make the branch truthy and hand the agent a blank tag.
    assert prompt =~ "No description provided."
    refute prompt =~ ~s(<external-content source="github"></external-content>)
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(Aiur.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid), do: ensure_workflow_store_running()
    end)

    assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.WorkflowStore)

    Workflow.set_workflow_file_path(Aiur.TestSupport.tmp_root!("missing-workflow") <> ".md")

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo operator .aiur/config renders correctly" do
    workflow_path = Workflow.workflow_file_path()

    Workflow.set_workflow_file_path(Path.expand("../.aiur/config", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for the prompt",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "MT-616"
    assert prompt =~ "Use rich templates for the prompt"
    assert prompt =~ "In Progress"
    assert prompt =~ "Render with rich template variables"
    assert prompt =~ "templating"
    assert prompt =~ "workflow"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "Continuation context:"
    assert prompt =~ ~r/[Rr]etry attempt #2/
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    # `PromptBuilder` prepends a shared-agent-instructions block when
    # the file is present at `prompts/shared-agent-instructions.md`,
    # so we assert on the rendered tail rather than equality.
    assert String.ends_with?(prompt, "Retry #2")
  end
end
