Tinytest.add "tracker - reactive variable", (test) ->
  try
    computation = null
    variable = new ReactiveVar 0

    runs = []

    computation = Tracker.autorun ->
      runs.push variable.get()

    variable.set 1
    Tracker.flush()

    variable.set 1
    Tracker.flush()

    variable.set 2
    Tracker.flush()

    test.equal runs, [0, 1, 2]

  finally
    computation?.stop()

# To test if afterFlush callbacks are run in the same order on the client and server.
Tinytest.add "tracker - invalidations inside autorun", (test) ->
  try
    computation = null
    variable = new ReactiveVar 0

    runs = []

    Tracker.afterFlush ->
      runs.push 'flush1'

    computation = Tracker.autorun ->
      Tracker.afterFlush ->
        runs.push 'flush-before'

      runs.push variable.get()
      variable.set variable.get() + 1 if variable.get() < 3

      Tracker.afterFlush ->
        runs.push 'flush-after'

    Tracker.afterFlush ->
      runs.push 'flush2'

    variable.set 1
    Tracker.flush()

    Tracker.afterFlush ->
      runs.push 'flush3'

    variable.set 1
    Tracker.flush()

    Tracker.afterFlush ->
      runs.push 'flush4'

    variable.set 2
    Tracker.flush()

    test.equal runs, [0, 1, 2, 3, 'flush1', 'flush-before', 'flush-after', 'flush2', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 1, 2, 3, 'flush3', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 2, 3, 'flush4', 'flush-before', 'flush-after', 'flush-before', 'flush-after']

  finally
    computation?.stop()

if Meteor.isServer
  # Should be the same order as above, just that we are adding some yields.
  Tinytest.add "tracker - invalidations inside autorun with yields", (test) ->
    try
      computation = null
      variable = new ReactiveVar 0

      runs = []

      Tracker.afterFlush ->
        runs.push 'flush1'

      computation = Tracker.autorun ->
        Tracker.afterFlush ->
          runs.push 'flush-before'

        runs.push variable.get()

        Meteor._sleepForMs 1

        variable.set variable.get() + 1 if variable.get() < 3

        Meteor._sleepForMs 1

        Tracker.afterFlush ->
          runs.push 'flush-after'

      Tracker.afterFlush ->
        runs.push 'flush2'

      variable.set 1

      Meteor._sleepForMs 1

      Tracker.flush()

      Tracker.afterFlush ->
        runs.push 'flush3'

      variable.set 1

      Meteor._sleepForMs 1

      Tracker.flush()

      Tracker.afterFlush ->
        runs.push 'flush4'

      variable.set 2

      Meteor._sleepForMs 1

      Tracker.flush()

      test.equal runs, [0, 1, 2, 3, 'flush1', 'flush-before', 'flush-after', 'flush2', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 1, 2, 3, 'flush3', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 2, 3, 'flush4', 'flush-before', 'flush-after', 'flush-before', 'flush-after']

    finally
      computation?.stop()

if Meteor.isClient
  collection = new Mongo.Collection null
else
  collection = new Mongo.Collection 'test_collection'

Tinytest.add "tracker - queries", (test) ->
  collection.remove {}

  try
    computations = []
    variable = new ReactiveVar 0

    runs = []

    computations.push Tracker.autorun ->
      collection.insert variable: variable.get()

    computations.push Tracker.autorun ->
      variable.get()

      if Meteor.isServer
        # Sleep a bit. To test blocking operations.
        Meteor._sleepForMs 250

      # Non-reactive so that it is the same on client and server.
      # But on the server this is a blocking operation.
      runs.push collection.findOne({}, reactive: false)?.variable

    computations.push Tracker.autorun ->
      variable.get()
      collection.remove {}

    variable.set 1
    Tracker.flush()

    variable.set 1
    Tracker.flush()

    variable.set 2
    Tracker.flush()

    test.equal runs, [0, 1, 2]

  finally
    for computation in computations
      computation.stop()

Tinytest.add "tracker - local queries", (test) ->
  localCollection = new Mongo.Collection null

  try
    computations = []
    variable = new ReactiveVar 0

    runs = []

    computations.push Tracker.autorun ->
      localCollection.insert variable: variable.get()

    computations.push Tracker.autorun ->
      # Minimongo is reactive both on the client and server.
      runs.push localCollection.findOne({})?.variable
      localCollection.remove {}

    variable.set 1
    Tracker.flush()

    variable.set 1
    Tracker.flush()

    variable.set 2
    Tracker.flush()

    test.equal runs, [0, undefined, 1, undefined, 2, undefined]

  finally
    for computation in computations
      computation.stop()

if Meteor.isServer
  Tinytest.add "tracker - flush with fibers", (test) ->
    # Register an afterFlush callback. This will call defer and schedule a flush to
    # be executed once the current fiber yields.
    afterFlushHasExecuted = false
    Tracker.afterFlush ->
      afterFlushHasExecuted = true

    # Create a new computation in this fiber.
    Tracker.autorun ->
      # Inside the computation, we yield so other fibers may run. This will cause the
      # deferred flush to execute.
      Meteor._sleepForMs 500

    # Now we are outside any computations. If everything works correctly, doing another
    # yield here should properly execute the flush and thus the afterFlush callback.
    Meteor._sleepForMs 500

    # If everything worked, afterFlush has executed.
    test.isTrue afterFlushHasExecuted

  Tinytest.add "tracker - parallel computations with fibers", (test) ->
    # Spawn some fibers.
    Fiber = Npm.require 'fibers'
    Future = Npm.require 'fibers/future'
    # The first fiber runs a computation and yields for 100 ms while in computation.
    futureA = new Future()
    fiberA = Fiber ->
      Tracker.autorun ->
        Meteor._sleepForMs 100

      futureA.return()
    fiberA.run()
    # The second fiber runs a computation and yields for 200 ms while in computation.
    futureB = new Future()
    fiberB = Fiber ->
      Tracker.autorun ->
        Meteor._sleepForMs 200
      futureB.return()
    fiberB.run()

    # Wait for both fibers to finish. If handled incorrectly, this could cause computation
    # state corruption, causing the any later flushes to never run.
    futureA.wait()
    futureB.wait()

    # Register an afterFlush callback. This will call defer and schedule a flush to
    # be executed once the current fiber yields.
    afterFlushHasExecuted = false
    Tracker.afterFlush ->
      afterFlushHasExecuted = true

    # We yield the current fiber and the afterFlush must run.
    Meteor._sleepForMs 500

    # If everything worked, afterFlush has executed.
    test.isTrue afterFlushHasExecuted
