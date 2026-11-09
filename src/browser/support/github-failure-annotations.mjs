import path from "node:path";
import { fileURLToPath } from "node:url";
import { PROBE_SPECS } from "../scripts/browser-quarantine.mjs";

const browserRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const testsRoot = path.resolve(browserRoot, "tests");
const maxAnnotations = 10;

function escapeProperty(value) {
  return String(value)
    .replaceAll("%", "%25")
    .replaceAll("\r", "%0D")
    .replaceAll("\n", "%0A")
    .replaceAll(":", "%3A")
    .replaceAll(",", "%2C");
}

function escapeData(value) {
  return String(value)
    .replaceAll("%", "%25")
    .replaceAll("\r", "%0D")
    .replaceAll("\n", "%0A");
}

export function failedSpecAnnotationLines(failures) {
  const tests = new Map();

  for (const failure of failures) {
    if (!["failed", "timedOut"].includes(failure.status)) continue;
    const file = failure.file ?? failure.location?.file;
    if (typeof file !== "string" || !path.isAbsolute(file)) continue;
    const relativeToTests = path.relative(testsRoot, file);
    if (
      !relativeToTests ||
      relativeToTests.startsWith("..") ||
      path.isAbsolute(relativeToTests) ||
      !relativeToTests.endsWith(".spec.mjs")
    )
      continue;
    const spec = path.posix.join(
      "src/browser/tests",
      relativeToTests.split(path.sep).join("/"),
    );
    const title = failure.titlePath?.filter(Boolean).at(-1) ?? failure.title;
    const line = failure.line ?? failure.location?.line;
    if (
      typeof title !== "string" ||
      title.length === 0 ||
      !Number.isInteger(line) ||
      line < 1
    )
      continue;
    tests.set(`${spec}\t${title}\t${line}`, { spec, title, line });
  }

  // The intentional-failure probes fail by design: never a quarantine candidate.
  const failuresByTest = [...tests.values()]
    .filter(({ spec }) => !PROBE_SPECS.includes(spec))
    .sort((a, b) =>
      `${a.spec}\t${a.title}\t${a.line}`.localeCompare(
        `${b.spec}\t${b.title}\t${b.line}`,
      ),
    );
  const lines = failuresByTest
    .slice(0, maxAnnotations)
    .map(({ spec, title, line }) => {
      const message = `new-failure :: BrowserSpec :: ${spec} :: ${title} :: ${line}`;
      return `::error title=aiur-test-failure,file=${escapeProperty(spec)},line=${line}::${escapeData(message)}`;
    });

  if (failuresByTest.length > maxAnnotations)
    lines.push(
      `::error title=aiur-test-failure::truncated :: and ${failuresByTest.length - maxAnnotations} more`,
    );
  return lines;
}
