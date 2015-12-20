class ServerAutorunTestCase extends ClassyTestCase
  @testName: 'server-autorun'

  setUpServer: ->
    @collection ?= new Mongo.Collection 'test_collection'
    @collection.remove {}

  setUpClient: ->
    @collection ?= new Mongo.Collection null
    @collection.remove {}

  testReactiveVariable: ->
    try
      computation = null
      variable = new ReactiveVar 0

      runs = []

      computation = Tracker.autorun (computation) =>
        runs.push variable.get()

      variable.set 1
      Tracker.flush()

      variable.set 1
      Tracker.flush()

      variable.set 2
      Tracker.flush()

      @assertEqual runs, [0, 1, 2]

    finally
      computation?.stop()

  # To test if afterFlush callbacks are run in the same order on the client and server.
  testIvalidationsInsideAutorun: ->
    try
      computation = null
      variable = new ReactiveVar 0

      runs = []

      Tracker.afterFlush ->
        runs.push 'flush1'

      computation = Tracker.autorun (computation) =>
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

      @assertEqual runs, [0, 1, 2, 3, 'flush1', 'flush-before', 'flush-after', 'flush2', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 1, 2, 3, 'flush3', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 2, 3, 'flush4', 'flush-before', 'flush-after', 'flush-before', 'flush-after']

    finally
      computation?.stop()

  # Should be the same order as above, just that we are adding some yields.
  testServerInvalidationsInsideAutorunWithYields: ->
    try
      computation = null
      variable = new ReactiveVar 0

      runs = []

      Tracker.afterFlush ->
        runs.push 'flush1'

      computation = Tracker.autorun (computation) =>
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

      @assertEqual runs, [0, 1, 2, 3, 'flush1', 'flush-before', 'flush-after', 'flush2', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 1, 2, 3, 'flush3', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 'flush-before', 'flush-after', 2, 3, 'flush4', 'flush-before', 'flush-after', 'flush-before', 'flush-after']

    finally
      computation?.stop()

  testQueries: ->
    try
      computations = []
      variable = new ReactiveVar 0

      runs = []

      computations.push Tracker.autorun (computation) =>
        @collection.insert variable: variable.get()

      computations.push Tracker.autorun (computation) =>
        variable.get()

        if Meteor.isServer
          # Sleep a bit. To test blocking operations.
          Meteor._sleepForMs 250

        # Non-reactive so that it is the same on client and server.
        # But on the server this is a blocking operation.
        runs.push @collection.findOne({}, reactive: false)?.variable

      computations.push Tracker.autorun (computation) =>
        variable.get()
        @collection.remove {}

      variable.set 1
      Tracker.flush()

      variable.set 1
      Tracker.flush()

      variable.set 2
      Tracker.flush()

      @assertEqual runs, [0, 1, 2]

    finally
      for computation in computations
        computation.stop()

  testLocalQueries: ->
    localCollection = new Mongo.Collection null

    try
      computations = []
      variable = new ReactiveVar 0

      runs = []

      computations.push Tracker.autorun (computation) =>
        localCollection.insert variable: variable.get()

      computations.push Tracker.autorun (computation) =>
        # Minimongo is reactive both on the client and server.
        runs.push localCollection.findOne({})?.variable
        localCollection.remove {}

      variable.set 1
      Tracker.flush()

      variable.set 1
      Tracker.flush()

      variable.set 2
      Tracker.flush()

      @assertEqual runs, [0, undefined, 1, undefined, 2, undefined]

    finally
      for computation in computations
        computation.stop()

  testServerFlushWithFibers: ->
    try
      computation = null

      # Register an afterFlush callback. This will call defer and schedule a flush to
      # be executed once the current fiber yields.
      afterFlushHasExecuted = false
      Tracker.afterFlush ->
        afterFlushHasExecuted = true

      # Create a new computation in this fiber.
      computation = Tracker.autorun (computation) =>
        # Inside the computation, we yield so other fibers may run. This will cause the
        # deferred flush to execute.
        Meteor._sleepForMs 500

      # Now we are outside any computations. If everything works correctly, doing another
      # yield here should properly execute the flush and thus the afterFlush callback.
      Meteor._sleepForMs 500

      # If everything worked, afterFlush has executed.
      @assertTrue afterFlushHasExecuted

    finally
      computation?.stop()

  testServerParallelComputationsWithFibers: ->
    try
      computations = []

      # Spawn some fibers.
      Fiber = Npm.require 'fibers'
      Future = Npm.require 'fibers/future'
      # The first fiber runs a computation and yields for 100 ms while in computation.
      futureA = new Future()
      fiberA = Fiber =>
        computations.push Tracker.autorun (computation) =>
          Meteor._sleepForMs 100

        futureA.return()
      fiberA.run()
      # The second fiber runs a computation and yields for 200 ms while in computation.
      futureB = new Future()
      fiberB = Fiber =>
        computations.push Tracker.autorun (computation) =>
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
      @assertTrue afterFlushHasExecuted

    finally
      for computation in computations
        computation.stop()

  testServerBlockingStop: ->
    trigger = new ReactiveVar 0
    startedAutorun = false
    finishedAutorun = false

    computation = Tracker.autorun (computation) =>
      trigger.get()
      return if computation.firstRun

      startedAutorun = true
      Meteor._sleepForMs 100
      finishedAutorun = true

    trigger.set 1

    # We sleep a bit (but less than 100 ms) to allow flushing to start.
    Meteor._sleepForMs 10

    @assertTrue startedAutorun
    @assertFalse finishedAutorun

    # Computation is still in progress (sleeping) when we stop it.
    # Stop should block until the computation finishes.
    computation.stop()

    @assertTrue startedAutorun
    @assertTrue finishedAutorun

  testServerNonfiberInvalidation: ->
    trigger = new ReactiveVar 0
    runs = []

    computation = Tracker.autorun (computation) =>
      runs.push trigger.get()

    exception = Meteor.bindEnvironment (error) =>
      @assertFail
        type: 'exception'
        message: error.message
        stack: error.stack

    setTimeout =>
      try
        trigger.set 1
      catch error
        exception error
    ,
      5

    Meteor._sleepForMs 20

    @assertEqual runs, [0, 1]

    computation.stop()

# Register the test case.
ClassyTestCase.addTest new ServerAutorunTestCase()
