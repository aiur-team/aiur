import { fileURLToPath } from 'node:url'

export const marker = '<!-- aiur-home-parity-nightly -->'
const title = 'Home parity nightly failed on main'
const author = 'github-actions[bot]'

// Only the scheduled main workflow receives issue-write permission. PRs and merge groups never report.
export async function reportNightly(environment = process.env, request = fetch) {
  if (environment.GITHUB_EVENT_NAME !== 'schedule' || environment.GITHUB_REF !== 'refs/heads/main') {
    throw new Error('Nightly reporter requires the scheduled main run')
  }
  const repository = environment.GITHUB_REPOSITORY
  const sha = environment.GITHUB_SHA
  const run = environment.GITHUB_RUN_ID
  const attempt = environment.GITHUB_RUN_ATTEMPT
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository || '') || !/^[a-f0-9]{40}$/.test(sha || '') ||
      !/^\d+$/.test(run || '') || !/^\d+$/.test(attempt || '') || !environment.GH_TOKEN) {
    throw new Error('Incomplete nightly run identity or credential')
  }
  const runUrl = `https://github.com/${repository}/actions/runs/${run}/attempts/${attempt}`
  const occurrence = `<!-- home-parity-run:${run}:${attempt} -->`
  const body = `${marker}\n${occurrence}\n\nThe full home-page parity matrix failed on main. This may be visual drift, a test failure, or fixture/toolchain infrastructure; inspect the evidence before classifying it.\n\n- Run and job logs: ${runUrl}\n- Tested head: ${sha}\n- Screenshot differences and traces: download the home-parity artifacts from the run (retained 14 days when produced).\n\nNo baseline is updated automatically. No agent is dispatched automatically.\n`
  async function api(path, method = 'GET', payload) {
    const response = await request(`https://api.github.com/repos/${repository}/${path}`, {
      method,
      headers: { Authorization: `Bearer ${environment.GH_TOKEN}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'Content-Type': 'application/json' },
      ...(payload ? { body: JSON.stringify(payload) } : {}),
      signal: AbortSignal.timeout(30_000)
    })
    if (!response.ok) throw new Error(`Nightly ticket ${method} failed: HTTP ${response.status}`)
    return response.json()
  }
  let existing
  for (let page = 1; page <= 20; page++) {
    const issues = await api(`issues?state=open&per_page=100&page=${page}`)
    if (!Array.isArray(issues)) throw new Error('Malformed issue census')
    existing = issues.find(issue => !issue.pull_request && issue.user?.login === author &&
      issue.title === title && issue.body?.startsWith(marker))
    if (existing || issues.length < 100) break
    if (page === 20) throw new Error('Incomplete issue census; refusing duplicate ticket')
  }
  if (existing) {
    // The open ticket body retains the initial failure; one comment records each later run.
    if (existing.body.includes(occurrence)) return existing.html_url
    for (let page = 1; page <= 20; page++) {
      const comments = await api(`issues/${existing.number}/comments?per_page=100&page=${page}`)
      if (!Array.isArray(comments)) throw new Error('Malformed comment census')
      if (comments.some(comment => comment.user?.login === author && comment.body?.startsWith(marker) &&
        comment.body.includes(occurrence))) return existing.html_url
      if (comments.length < 100) break
      if (page === 20) throw new Error('Incomplete comment census; refusing duplicate report')
    }
    const comment = await api(`issues/${existing.number}/comments`, 'POST', { body })
    const observed = await api(`issues/comments/${comment.id}`)
    if (observed.body !== body) throw new Error('Nightly comment read-back mismatch')
    return existing.html_url
  }
  const issue = await api('issues', 'POST', { title, body })
  const observed = await api(`issues/${issue.number}`)
  if (observed.body !== body || observed.title !== title) throw new Error('Nightly issue read-back mismatch')
  return observed.html_url
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  console.log(await reportNightly())
}
