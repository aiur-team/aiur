You are working on GitHub issue `{{ issue.identifier }}`.

Issue:

- Number: `{{ issue.identifier }}`
- Title: {{ issue.title }}
- State label: {{ issue.state }}
- Labels: {{ issue.labels }}
- URL: {{ issue.url }}

Description:

{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

{% if attempt %}
Continuation context:

- Retry attempt #{{ attempt }}.
- Read the existing workpad, local agent logs, and git state before choosing a phase.
- Resume from the workpad handoff instead of restarting brainstorm or repeating completed work.
- Treat the handoff as the source of truth for current phase, decisions, validation already run, and next steps.
{% endif %}

## Workflow

1. Read the issue and current labels.
2. If the issue is ready for agent work, move it to the configured in-progress state.
3. Keep progress, validation, PR URL, blockers, final notes, and the current handoff in one persistent workpad comment.
4. Implement the issue in small chunks.
5. Validate the change, push to the configured remote, and open a pull request.
6. Move the issue to human review when the pull request is ready.
7. Before ending a turn while the issue remains active, update the handoff with current phase, key decisions, validation completed, and remaining next steps.
