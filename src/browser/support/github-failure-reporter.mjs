import { failedSpecAnnotationLines } from './github-failure-annotations.mjs'

export default class GitHubFailureReporter {
  #failures = []

  constructor(_config, write = (line) => process.stdout.write(`${line}\n`)) {
    this.write = write
  }

  onTestEnd(test, result) {
    this.#failures.push({ file: test.location?.file, status: result.status })
  }

  onEnd() {
    if (process.env.GITHUB_ACTIONS !== 'true') return
    for (const line of failedSpecAnnotationLines(this.#failures)) this.write(line)
  }
}
