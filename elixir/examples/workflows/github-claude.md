---
tracker:
  kind: github
  active_states:
    - todo
    - in-progress
  terminal_states:
    - done
    - closed
github:
  repo: your-org/your-repo
  label_prefix: agent
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone "$SYMPHONY_REPOSITORY_URL" .
agent:
  kind: claude
  max_concurrent_agents: 5
  max_turns: 20
claude:
  command: symphony-claude
---

You are working on GitHub issue `{{ issue.identifier }}`.

Title: {{ issue.title }}

Body:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}
