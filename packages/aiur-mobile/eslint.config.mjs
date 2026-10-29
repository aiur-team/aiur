import eslint from "@eslint/js";
import tseslint from "typescript-eslint";
import hooks from "eslint-plugin-react-hooks";
import globals from "globals";

export default tseslint.config(
  { ignores: ["node_modules/**", "ios/**", "android/**", ".expo/**", "coverage/**", "dist/**"] },
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
  { languageOptions: { globals: globals.node } },
  { files: ["**/*.tsx"], plugins: { "react-hooks": hooks }, rules: hooks.configs.recommended.rules },
);
