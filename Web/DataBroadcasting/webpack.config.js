// SPDX-License-Identifier: GPL-2.0-or-later
const path = require('path');

module.exports = {
    entry: './src/main.ts',
    output: {
        path: path.resolve(__dirname, 'dist'),
        filename: 'main.js',
    },
    module: {
        rules: [{ test: /\.ts$/, use: 'ts-loader' }],
    },
    resolve: {
        extensions: ['.ts', '.js'],
    },
};
