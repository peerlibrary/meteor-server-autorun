Package.describe({
  summary: "Server-side Tracker.autorun",
  version: '0.5.0',
  name: 'peerlibrary:server-autorun',
  git: 'https://github.com/peerlibrary/meteor-server-autorun.git'
});

Package.onUse(function (api) {
  api.versionsFrom('METEOR@1.0.3.1');

  // Core dependencies.
  api.use([
    'coffeescript',
    'underscore',
    'tracker'
  ]);

  api.export('Tracker');

  // 3rd party dependencies.
  api.use([
    'peerlibrary:assert@0.2.5',
    'peerlibrary:fiber-utils@0.5.1'
  ], 'server');

  api.addFiles([
    'client.coffee'
  ], 'client');

  api.addFiles([
    'server.coffee'
  ], 'server');
});

Package.onTest(function (api) {
  // Core dependencies.
  api.use([
    'tinytest',
    'test-helpers',
    'coffeescript',
    'mongo',
    'reactive-var',
    'minimongo',
    'underscore',
    'ejson',
    'random',
    'mongo-id'
  ]);

  // Internal dependencies.
  api.use([
    'peerlibrary:server-autorun'
  ]);

  // 3rd party dependencies.
  api.use([
    'peerlibrary:classy-test@0.2.18'
  ]);

  api.addFiles([
    'meteor/packages/tracker/tracker_tests.js',
    'meteor/packages/minimongo/minimongo_tests.js',
    'tests.coffee'
  ]);
});
