import { readFileSync } from "node:fs";
import { resolve } from "node:path";

test("every runtime and development dependency is pinned exactly", () => {
  const manifest = JSON.parse(readFileSync(resolve(__dirname, "../package.json"), "utf8"));
  const dependencies = { ...manifest.dependencies, ...manifest.devDependencies };
  for (const [name, version] of Object.entries(dependencies)) {
    const exact = name === "@aiur/contracts"
      ? "file:../aiur-contracts"
      : expect.stringMatching(/^\d+\.\d+\.\d+$/);
    expect({ [name]: version }).toEqual({ [name]: exact });
  }
});
