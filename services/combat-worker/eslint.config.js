import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["dist/**", ".wrangler/**", "worker-configuration.d.ts"] },
  js.configs.recommended,
  tseslint.configs.recommendedTypeChecked,
  { files: ["**/*.js"], extends: [tseslint.configs.disableTypeChecked] },
  {
    files: ["**/*.ts"],
    languageOptions: { parserOptions: { project: ["./tsconfig.json"], tsconfigRootDir: import.meta.dirname } },
    rules: {
      "@typescript-eslint/consistent-type-imports": "error",
      "@typescript-eslint/no-explicit-any": "error"
    }
  }
);
