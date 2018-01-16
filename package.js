Package.describe({
  summary: "Server-side Tracker.autorun",
  version: '0.7.1',
  name: 'peerlibrary:server-autorun',
  git: 'https://github.com/peerlibrary/meteor-server-autorun.git'
});

Package.onUse(function (api) {
  api.versionsFrom('METEOR@1.4.4.5');

  // Core dependencies.
  api.use([
    'coffeescript@2.0.3_3',
    'ecmascript',
    'underscore',
    'tracker'
  ]);

  // 3rd party dependencies.
  api.use([
    'peerlibrary:assert@0.2.5',
    'peerlibrary:fiber-utils@0.9.1'
  ], 'server');

  api.export('Tracker');

  api.mainModule('client.coffee', 'client');
  api.mainModule('server.coffee', 'server');
});

Package.onTest(function (api) {
  api.versionsFrom('METEOR@1.4.4.5');

  // Core dependencies.
  api.use([
    'coffeescript@2.0.3_3',
    'ecmascript',
    'tinytest',
    'test-helpers',
    'mongo',
    'reactive-var',
    'minimongo',
    'underscore',
    'ejson',
    'random',
    'mongo-id',
    'id-map'
  ]);

  // Internal dependencies.
  api.use([
    'peerlibrary:server-autorun'
  ]);

  // 3rd party dependencies.
  api.use([
    'peerlibrary:classy-test@0.3.0'
  ]);

  api.addFiles([
    'meteor/packages/tracker/tracker_tests.js',
    'meteor/packages/minimongo/matcher.js',
    'meteor/packages/minimongo/minimongo_tests.js',
    'meteor/packages/minimongo/minimongo_tests_client.js',
    'tests.coffee'
  ]);
});
