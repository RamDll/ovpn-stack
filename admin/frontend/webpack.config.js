const path = require('path');

module.exports = {
    mode: 'production',
    entry: {
      bundle: [
        './src/main.js',
      ],
      style: [
        './src/style.js',
      ]
    },
    output: {
      path: path.resolve(__dirname, './static/dist'),
      publicPath: '/dist/',
      filename: '[name].min.js'
    },
    module: {
      rules: [
        {
          test: /\.css$/,
          use: [
            'vue-style-loader',
            'css-loader'
          ],
        },
        {
          test: /\.js$/,
          exclude: /node_modules/,
          loader: 'babel-loader',
          // конфигурация в .babelrc
        },
        {
          // шрифты/картинки из CSS зависимостей (bootstrap, vue-good-table)
          test: /\.(woff2?|ttf|eot|svg|png|jpe?g|gif)$/,
          type: 'asset/resource',
        },
      ],
    },
    resolve: {
      alias: {
        'vue$': 'vue/dist/vue.esm.js',
      },
      extensions: ['.js', '.json'],
    },
  }
