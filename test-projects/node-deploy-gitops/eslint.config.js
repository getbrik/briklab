module.exports = [
  {
    files: ["src/**/*.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "commonjs",
      globals: {
        console: "readonly",
        process: "readonly",
        module: "readonly",
        exports: "readonly",
        require: "readonly",
        __dirname: "readonly",
        __filename: "readonly",
      },
    },
    rules: {
      "no-unused-vars": "warn",
      "no-undef": "error",
    },
  },
];
