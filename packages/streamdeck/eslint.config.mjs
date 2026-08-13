import eslint from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    ignores: ["coverage", "dist"],
  },
  {
    files: ["scripts/**/*.mjs"],
    languageOptions: {
      globals: {
        URL: "readonly",
        process: "readonly",
        setTimeout: "readonly",
      },
    },
  },
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
);
