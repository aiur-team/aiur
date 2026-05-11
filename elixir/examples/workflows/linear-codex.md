---
tracker:
  kind: linear
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
linear:
  api_key: $LINEAR_API_KEY
  project_slug: your-project-slug
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone "$SYMPHONY_REPOSITORY_URL" .
  before_remove: |
    git status --short
agent:
  kind: codex
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on Linear issue `{{ issue.identifier }}`.

Title: {{ issue.title }}

Body:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}
