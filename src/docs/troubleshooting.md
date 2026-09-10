# Troubleshooting Guide

A guide to common issues encountered during Aiur setup and how to resolve them.

## Environment Variables & Authentication

### GitHub Token (`GITHUB_TOKEN`)

Aiur uses the GitHub Issues API to fetch issues, update labels, and post comments.
`GITHUB_TOKEN` is the default credential. A complete GitHub App credential set
is an optional alternative, recommended if agents are hitting rate limits; see
`docs/security/daemon-token-posture.md` for setup.

**Required scopes:**

| Scope | Purpose |
|-------|---------|
| `repo` | Read/write access to issues, PRs, and labels in private repositories |
| `issues:write` | Post issue comments, update labels, close issues |
| `pull_requests:write` | Create PRs and resolve pull request review threads |

If using a **fine-grained personal access token**:
- **Repository access**: Select the target repository
- **Issues**: Read and write
- **Pull requests**: Read and write (if PR creation or review-thread resolution is needed)
- **Contents**: Read (to read repository contents)

If using a **classic personal access token**:
- Select the `repo` scope (for private repos) or `public_repo` (for public repos)

**Setting the token:**

```bash
export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

**Symptoms & Diagnosis:**

Before polling or dispatching agent work, Aiur validates the exact `GITHUB_TOKEN`
value inherited by the daemon against the GitHub endpoint classes it needs
(`rate_limit`, repository access, and issue listing). If the token is invalid,
expired, missing repository access, or rate-limited enough to block tracker
operations, Aiur logs an actionable preflight error and skips GitHub polling for
that tick instead of launching agents that will fail later.

`GITHUB_TOKEN` takes precedence over `gh` keyring auth. A working `gh auth status`
in your shell does not help Aiur if the daemon inherited a stale or exhausted
`GITHUB_TOKEN` from `.env` or the launch environment.

If the token is missing or has insufficient permissions, Aiur reports errors such
as:

```
error: GitHub token missing - set GITHUB_TOKEN env var
```

Or, when preflight detects a bad inherited token:

```
GitHub auth preflight failed for GITHUB_TOKEN while validating owner/repo issues access: ...
Aiur uses GITHUB_TOKEN for GitHub tracker/API calls, and that environment token takes precedence over `gh` keyring auth.
```

Older or downstream failures may still look like:

```
error: GitHub API request failed status=403
error: GitHub API request failed status=404
```

- `403`: Insufficient token permissions. Check the required scopes listed above.
- `404`: No access to the repository, or the `github.repo` config value is incorrect.

Review-thread replies and review-thread resolution are separate GitHub GraphQL
permissions in practice. A token can successfully post a reply with
`addPullRequestReviewThreadReply` and still fail `resolveReviewThread` with:

```
Resource not accessible by personal access token
```

When that happens, Aiur reports `review_thread_resolution_not_permitted`. Use a
token with pull-request write access for the target repository (fine-grained:
**Pull requests: Read and write**; classic: `repo` for private repositories or
`public_repo` for public repositories). The verified reply remains the durable
record that the agent answered the review feedback; resolving the GitHub thread
requires the stronger token permission above.

Aiur also verifies the semantic trust boundary before resolving a review thread.
`aiur_resolve_review_thread` re-fetches the thread, confirms the exact terminal
agent reply is still the latest comment, and checks that the latest non-agent
reviewer comment is authoritative for the thread path according to CODEOWNERS.
If a newer reviewer reply appears, Aiur reports
`review_thread_resolution_precondition_failed` and leaves the thread unresolved.
If the reviewer is outside the CODEOWNERS trust boundary, Aiur reports
`review_thread_resolution_not_authorized`.

**Recovery:**

1. Fix `.env` or the shell used to launch Aiur so `GITHUB_TOKEN` points to the
   intended token, or unset `GITHUB_TOKEN` before launching if you are diagnosing
   keyring behavior.
2. Restart Aiur. A running daemon keeps the environment it started with.
3. Verify without printing token material:

   ```bash
   gh api rate_limit
   gh api repos/OWNER/REPO/issues?per_page=1
   ```

If those commands succeed only after unsetting `GITHUB_TOKEN`, the keyring login
is usable but the environment token is shadowing it.

### Linear API Key (`LINEAR_API_KEY`)

Required when using the Linear tracker.

```bash
export LINEAR_API_KEY="lin_api_xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

To generate a key: Linear > Settings > Security & access > Personal API keys

## Prompt Template Errors

The prompt template is the optional Markdown/Liquid file referenced by `prompt_file:`
in `.aiur/config`. These errors apply to that template file.

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

**Cause**: The prompt template file is saved in a non-UTF-8 encoding (e.g., EUC-KR,
CP949), or the issue data contains invalid bytes.

**Solution:**

1. Verify that the prompt template file is saved as UTF-8:
   ```bash
   file -bi my-prompt.md
   # Expected: text/plain; charset=utf-8
   ```
2. If it's not UTF-8, convert it:
   ```bash
   iconv -f EUC-KR -t UTF-8 my-prompt.md > my-prompt.utf8.md
   mv my-prompt.utf8.md my-prompt.md
   ```
3. Explicitly set the encoding to UTF-8 when saving in your editor.

## Agent Setup

### Claude Backend

`aiur-claude` must be installed:

```bash
brew install aiur-claude
```

`.aiur/config` configuration:

```yaml
claude:
  command: aiur-claude
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

Aiur manages issue state using labels with the `aiur:` prefix.
The following labels must be created in the repository beforehand:

- `aiur:todo` - Waiting to be worked on
- `aiur:in-progress` - Currently being worked on
- `aiur:done` - Completed (issue is automatically closed)
- `aiur:cancelled` - Cancelled (issue is automatically closed)

If you changed the `label_prefix`, create labels with the corresponding prefix.

## Checking Logs

Check the log files when diagnosing issues:

```bash
# Default log location
tail -f log/aiur.log

# Custom log path
aiur --logs-root /path/to/logs .aiur/config
```

## FAQ

### Aiur starts but doesn't fetch any issues

1. Verify that `GITHUB_TOKEN` or `LINEAR_API_KEY` is set
2. Verify that `github.repo` is in `owner/repo` format
3. Check that the repository has issues with the `aiur:todo` or `aiur:in-progress` label
4. Confirm the token has access to the target repository

### The agent keeps retrying in a loop

Check the error messages in the logs. Common causes:
- Incorrect variable names in the prompt template (see "Undefined Variable Error" above)
- Prompt template encoding issues (see "JSON Encoding Error" above)
- `aiur-claude` or `codex` command not found in PATH

### Can't access the observability dashboard

The dashboard is enabled by specifying a port with the `--port` option:

```bash
aiur --port 4000 .aiur/config
```

Then access it at `http://127.0.0.1:4000`.
