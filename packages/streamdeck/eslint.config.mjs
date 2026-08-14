import eslint from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    ignores: ["coverage", "dist"],
  },
  {
    files: ["scripts/**/*.mjs"],
    languageOptions: {
      // The render/probe scripts are plain Node programs, so they use the Node
      // globals the TypeScript sources reach through `@types/node`.
      globals: {
        Buffer: "readonly",
        URL: "readonly",
        console: "readonly",
        process: "readonly",
        setImmediate: "readonly",
        setTimeout: "readonly",
      },
    },
  },
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
);
