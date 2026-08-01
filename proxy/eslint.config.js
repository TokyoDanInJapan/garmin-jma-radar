// ESLint flat config for the Worker, its tests, and the dev scripts.
//
// This complements `npm run typecheck` rather than duplicating it: tsc --checkJs
// validates the JSDoc types on src/, and ESLint catches the things types don't
// – unused bindings, accidental globals, sloppy equality, unreachable code –
// across all three source trees, including test/ and scripts/ which tsconfig
// deliberately leaves out of scope.
import js from "@eslint/js";
import globals from "globals";

export default [
  { ignores: ["dist/**", ".wrangler/**", "node_modules/**"] },

  js.configs.recommended,

  {
    // The deployed Worker. Cloudflare's runtime is service-worker-shaped
    // (fetch, caches, Response) but is not Node: keeping the globals tight here
    // means a stray `process.env` or `Buffer` is caught in CI rather than at the
    // edge, where it would throw on a live request.
    files: ["src/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      globals: {
        ...globals.serviceworker,
        caches: "readonly",
        console: "readonly",
        fetch: "readonly",
        AbortSignal: "readonly",
        URL: "readonly",
        URLSearchParams: "readonly",
      },
    },
    rules: {
      eqeqeq: ["error", "always", { null: "ignore" }], // `== null` is the idiom used for absent params
      "no-var": "error",
      "prefer-const": "error",
      "no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
    },
  },

  {
    // node:test suites and the sample/GIF generators. Node globals, and the
    // test helpers intentionally stub globals like `caches`, so those are writable.
    files: ["test/**/*.js", "scripts/**/*.mjs"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "module",
      globals: {
        ...globals.node,
        caches: "writable",
      },
    },
    rules: {
      "no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
    },
  },
];
