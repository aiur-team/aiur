# Troubleshooting Guide

A guide to common issues encountered during Symphony setup and how to resolve them.

## Environment Variables & Authentication

### GitHub Token (`GITHUB_TOKEN`)

Symphony uses the GitHub Issues API to fetch issues, update labels, and post comments.
The `GITHUB_TOKEN` environment variable must be set.

**Required scopes:**

| Scope | Purpose |
|-------|---------|
| `repo` | Read/write access to issues, PRs, and labels in private repositories |
| `issues:write` | Post issue comments, update labels, close issues |
| `pull_requests:write` | Required if the agent creates PRs |

If using a **fine-grained personal access token**:
- **Repository access**: Select the target repository
- **Issues**: Read and write
- **Pull requests**: Read and write (if PR creation is needed)
- **Contents**: Read (to read repository contents)

If using a **classic personal access token**:
- Select the `repo` scope (for private repos) or `public_repo` (for public repos)

**Setting the token:**

```bash
export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

**Symptoms & Diagnosis:**

If the token is missing or has insufficient permissions, Symphony will start but produce repeated errors during polling:

```
error: GitHub token missing - set GITHUB_TOKEN env var
```

Or if the token exists but lacks required permissions:

```
error: GitHub API request failed status=403
error: GitHub API request failed status=404
```

- `403`: Insufficient token permissions. Check the required scopes listed above.
- `404`: No access to the repository, or the `github.repo` config value is incorrect.

### Linear API Key (`LINEAR_API_KEY`)

Required when using the Linear tracker.

```bash
export LINEAR_API_KEY="lin_api_xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

To generate a key: Linear > Settings > Security & access > Personal API keys

## WORKFLOW.md Prompt Template Errors

### Undefined Variable Error

```
(Solid.RenderError) Undefined variable issue.number
```

**Cause**: The prompt template references a variable name that does not exist on the `Issue` struct.

**Available template variables:**

| Variable | Type | Description |
|----------|------|-------------|
| `issue.id` | String | Unique issue ID (GitHub: issue number) |
| `issue.identifier` | String | Issue identifier (GitHub: issue number, Linear: issue key) |
| `issue.title` | String | Issue title |
| `issue.description` | String | Issue body |
| `issue.state` | String | Current state (e.g., `todo`, `in-progress`) |
| `issue.url` | String | Issue web URL |
| `issue.labels` | List | List of labels |
| `issue.assignee_id` | String | Assignee ID (GitHub: login, Linear: user ID) |
| `issue.priority` | Integer | Priority (1-4, nil) |
| `issue.branch_name` | String | Associated branch name (Linear) |
| `issue.created_at` | DateTime | Creation timestamp |
| `issue.updated_at` | DateTime | Last updated timestamp |
| `attempt` | Integer | Retry count (nil on first run) |

**Common variable name mistakes:**

| Incorrect | Correct |
|-----------|---------|
| `issue.number` | `issue.identifier` |
| `issue.assignees` | `issue.assignee_id` |
| `issue.body` | `issue.description` |
| `issue.status` | `issue.state` |

**Correct template example:**

```liquid
You are working on GitHub Issue `#{{ issue.identifier }}` in `owner/repo`.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
URL: {{ issue.url }}
Assignee: {{ issue.assignee_id }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}
```

### JSON Encoding Error (Non-ASCII Characters)

```
(Jason.EncodeError) invalid byte 0xEC in <<...>>
```

**Cause**: The WORKFLOW.md file is saved in a non-UTF-8 encoding (e.g., EUC-KR, CP949),
or the issue data contains invalid bytes.

**Solution:**

1. Verify that WORKFLOW.md is saved as UTF-8:
   ```bash
   file -bi WORKFLOW.md
   # Expected: text/plain; charset=utf-8
   ```
2. If it's not UTF-8, convert it:
   ```bash
   iconv -f EUC-KR -t UTF-8 WORKFLOW.md > WORKFLOW.utf8.md
   mv WORKFLOW.utf8.md WORKFLOW.md
   ```
3. Explicitly set the encoding to UTF-8 when saving in your editor.

## Agent Setup

### Claude Backend

`symphony-claude` must be installed:

```bash
brew install symphony-claude
```

WORKFLOW.md configuration:

```yaml
claude:
  command: symphony-claude
```

### Codex Backend

```yaml
codex:
  command: codex app-server
```

## Workspace Issues

### Hook Execution Failure

If `git clone` fails in `hooks.after_create`:

```
Agent run failed for issue_id=...: hook_failed
```

**Checklist:**
- Verify that SSH keys are configured (`ssh -T git@github.com`)
- Verify that the Git URL is correct
- If using `mise`, make sure you have run `mise trust`

### Workspace Disk Space

Each issue clones the repository, which can consume significant disk space.
Using `--depth 1` for a shallow clone is recommended:

```yaml
hooks:
  after_create: |
    git clone --depth 1 git@github.com:owner/repo.git .
```

## GitHub Issues Label Setup

Symphony manages issue state using labels with the `symphony:` prefix.
The following labels must be created in the repository beforehand:

- `symphony:todo` - Waiting to be worked on
- `symphony:in-progress` - Currently being worked on
- `symphony:done` - Completed (issue is automatically closed)
- `symphony:cancelled` - Cancelled (issue is automatically closed)

If you changed the `label_prefix`, create labels with the corresponding prefix.

## Checking Logs

Check the log files when diagnosing issues:

```bash
# Default log location
tail -f log/symphony.log

# Custom log path
symphony --logs-root /path/to/logs WORKFLOW.md
```

## FAQ

### Symphony starts but doesn't fetch any issues

1. Verify that `GITHUB_TOKEN` or `LINEAR_API_KEY` is set
2. Verify that `github.repo` is in `owner/repo` format
3. Check that the repository has issues with the `symphony:todo` or `symphony:in-progress` label
4. Confirm the token has access to the target repository

### The agent keeps retrying in a loop

Check the error messages in the logs. Common causes:
- Incorrect variable names in the prompt template (see "Undefined Variable Error" above)
- WORKFLOW.md encoding issues (see "JSON Encoding Error" above)
- `symphony-claude` or `codex` command not found in PATH

### Can't access the observability dashboard

The dashboard is enabled by specifying a port with the `--port` option:

```bash
symphony --port 4000 WORKFLOW.md
```

Then access it at `http://127.0.0.1:4000`.
