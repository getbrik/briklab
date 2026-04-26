import js from '@eslint/js';

export default [
js.configs.recommended,
{
    languageOptions: {
    ecmaVersion: 'latest',
    sourceType: 'commonjs',
    globals: {
        process: 'readonly',
        console: 'readonly',
        module: 'readonly',
        require: 'readonly',
        __dirname: 'readonly',
        __filename: 'readonly',
    },
    },
    rules: {
    'no-unused-vars': 'warn',
    'no-undef': 'error',
    },
},
];