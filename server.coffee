import {Tracker} from 'meteor/tracker'

import Fiber from 'fibers'
import Future from 'fibers/future'

# Tracker.Computation constructor is private, so we are using this object as a guard.
# External code cannot access this, and will not be able to directly construct a
# Tracker.Computation instance.
privateObject = {}

# Guard object for fiber utils.
guard = {}

nextId = 1

class TrackerInstance
  constructor: ->
    @active = false
    @currentComputation = null

    @pendingComputations = []
    @willFlush = false
    @inFlush = null
    @inRequireFlush = false
    @inCompute = false
    @throwFirstError = false
    @afterFlushCallbacks = []

  setCurrentComputation: (computation) ->
    @currentComputation = computation
    @active = !!computation

  # Copied from tracker.js.
  _debugFunc: ->
    return Meteor._debug if Meteor?._debug

    if console?.error
      return ->
        console.error.apply console, arguments

    return ->

  # Copied from tracker.js.
  _maybeSuppressMoreLogs: (messagesLength) ->
    if typeof Meteor isnt "undefined"
      if Meteor._suppressed_log_expected()
        Meteor._suppress_log(messagesLength - 1)

  # Copied from tracker.js.
  _throwOrLog: (from, error) ->
    if @throwFirstError
      throw error
    else
      printArgs = ["Exception from Tracker " + from + " function:"]
      if error.stack and error.message and error.name
        idx = error.stack.indexOf error.message
        if idx < 0 or idx > error.name.length + 2
          message = error.name + ": " + error.message
          printArgs.push message
      printArgs.push error.stack
      @_maybeSuppressMoreLogs printArgs.length

      for printArg in printArgs
        @_debugFunc() printArg

  _deferAndTransfer: (func) ->
    # Defer execution of a function, which will create a new fiber. Make the resulting
    # fiber share ownership of the same tracker instance as it will serve only as its
    # extension for executing its flushes.
    Meteor.defer =>
      assert not Fiber.current._trackerInstance

      try
        Fiber.current._trackerInstance = @
        func()
      finally
        Fiber.current._trackerInstance = null

  requireFlush: ->
    return if @willFlush

    @_deferAndTransfer =>
      @_runFlush
        fromRequireFlush: true

    @willFlush = true

  _runFlush: (options) ->
    if @inFlush instanceof Future
      # If there are two runs from requireFlush in sequence, we simply skip the second one, the first
      # one is still in progress.
      return if options?.fromRequireFlush

      # We wait for the previous flush from requireFlush to finish before continuing.
      @inFlush.wait()
      assert not @inFlush

    # If already in flush and this is a flush from requireFlush, just skip it.
    return if @inFlush and options?.fromRequireFlush

    throw new Error "Can't call Tracker.flush while flushing" if @inFlush

    if @inCompute
      if options?.fromRequireFlush
        # If this fiber is currently running a computation and a require flush has been
        # deferred, we need to defer again and retry.
        @_deferAndTransfer =>
          @_runFlush options
        return

      throw new Error "Can't flush inside Tracker.autorun"

    # If this is a run from requireFlush, provide a future so that calls to flush can wait on it.
    if options?.fromRequireFlush
      @inFlush = new Future()
    else
      @inFlush = true

    @willFlush = true
    @throwFirstError = !!options?.throwFirstError

    recomputedCount = 0
    finishedTry = false
    try
      while @pendingComputations.length or @afterFlushCallbacks.length

        while @pendingComputations.length
          computation = @pendingComputations.shift()
          computation._recompute()
          if computation._needsRecompute()
            @pendingComputations.unshift computation

          if not options?.finishSynchronously and ++recomputedCount > 1000
            finishedTry = true
            return

        if @afterFlushCallbacks.length
          func = @afterFlushCallbacks.shift()
          try
            func()
          catch error
            @_throwOrLog "afterFlush", error

      finishedTry = true
    finally
      # We first have to set @inFlush to null, then we can return.

      inFlush = @inFlush
      unless finishedTry
        @inFlush = null
        inFlush.return() if inFlush instanceof Future
        @_runFlush
          finishSynchronously: options?.finishSynchronously
          throwFirstError: false

      @willFlush = false
      @inFlush = null
      inFlush.return() if inFlush instanceof Future
      if @pendingComputations.length or @afterFlushCallbacks.length
        throw new Error "still have more to do?" if options?.finishSynchronously
        Meteor.setTimeout =>
          @requireFlush()
        , 10 # ms

Tracker._computations = {}

Tracker._trackerInstance = ->
  Meteor._nodeCodeMustBeInFiber()
  Fiber.current._trackerInstance ?= new TrackerInstance()

Tracker.flush = (options) ->
  Tracker._trackerInstance()._runFlush
    finishSynchronously: true
    throwFirstError: options?._throwFirstError

Tracker.inFlush = ->
  Tracker._trackerInstance().inFlush

Tracker.autorun = (func, options) ->
  throw new Error "Tracker.autorun requires a function argument" unless typeof func is "function"

  c = new Tracker.Computation func, Tracker.currentComputation, options?.onError, privateObject

  if Tracker.active
    Tracker.onInvalidate ->
      c.stop()

  c

Tracker.nonreactive = (f) ->
  trackerInstance = Tracker._trackerInstance()
  previous = trackerInstance.currentComputation
  trackerInstance.setCurrentComputation null
  try
    return f()
  finally
    trackerInstance.setCurrentComputation previous

Tracker.onInvalidate = (f) ->
  throw new Error "Tracker.onInvalidate requires a currentComputation" unless Tracker.active

  Tracker.currentComputation.onInvalidate f

Tracker.afterFlush = (f) ->
  trackerInstance = Tracker._trackerInstance()
  trackerInstance.afterFlushCallbacks.push f
  trackerInstance.requireFlush()

# Compatibility with the client-side Tracker. On node.js we can use defineProperties to define getters.
Object.defineProperties Tracker,
  currentComputation:
    get: ->
      Tracker._trackerInstance().currentComputation

  active:
    get: ->
      Tracker._trackerInstance().active

class Tracker.Computation
  constructor: (func, @_parent, @_onError, _private) ->
    throw new Error "Tracker.Computation constructor is private; use Tracker.autorun" if _private isnt privateObject

    @stopped = false
    @invalidated = false
    @firstRun = true
    @_id = nextId++
    @_onInvalidateCallbacks = []
    @_onStopCallbacks = []
    @_beforeRunCallbacks = []
    @_afterRunCallbacks = []
    @_recomputing = false

    @_trackerInstance = Tracker._trackerInstance()

    onException = (error) =>
      throw error if @firstRun

      if @_onError
        @_onError error
      else
        @_trackerInstance._throwOrLog "recompute", error

    @_func = Meteor.bindEnvironment func, onException, @

    Tracker._computations[@_id] = @

    errored = true
    try
      @_compute()
      errored = false
    finally
      @firstRun = false
      @stop() if errored

  onInvalidate: (f) ->
    FiberUtils.ensure =>
      throw new Error "onInvalidate requires a function" unless typeof f is "function"

      if @invalidated
        Tracker.nonreactive =>
          f @
      else
        @_onInvalidateCallbacks.push f

  onStop: (f) ->
    FiberUtils.ensure =>
      throw new Error "onStop requires a function" unless typeof f is "function"

      if @stopped
        Tracker.nonreactive =>
          f @
      else
        @_onStopCallbacks.push f

  beforeRun: (f) ->
    throw new Error "beforeRun requires a function" unless typeof f is "function"

    @_beforeRunCallbacks.push f

  afterRun: (f) ->
    throw new Error "afterRun requires a function" unless typeof f is "function"

    @_afterRunCallbacks.push f

  invalidate: ->
    FiberUtils.ensure =>
      # TODO: Why some tests freeze if we wrap this method into FiberUtils.synchronize?
      if not @invalidated
        if not @_recomputing and not @stopped
          @_trackerInstance.requireFlush()
          @_trackerInstance.pendingComputations.push @

        @invalidated = true

        for callback in @_onInvalidateCallbacks
          Tracker.nonreactive =>
            callback @
        @_onInvalidateCallbacks = []

  stop: ->
    FiberUtils.ensure =>
      FiberUtils.synchronize guard, @_id, =>
        return if @stopped
        @stopped = true

        @invalidate()

        delete Tracker._computations[@_id]

        while @_onStopCallbacks.length
          callback = @_onStopCallbacks.shift()
          Tracker.nonreactive =>
            callback @

  # Runs an arbitrary function inside the computation. This allows breaking many assumptions, so use it very carefully.
  _runInside: (func) ->
    FiberUtils.synchronize guard, @_id, =>
      Meteor._nodeCodeMustBeInFiber()
      previousTrackerInstance = Tracker._trackerInstance()
      Fiber.current._trackerInstance = @_trackerInstance
      previousComputation = @_trackerInstance.currentComputation
      @_trackerInstance.setCurrentComputation @
      previousInCompute = @_trackerInstance.inCompute
      @_trackerInstance.inCompute = true
      try
        func @
      finally
        Fiber.current._trackerInstance = previousTrackerInstance
        @_trackerInstance.setCurrentComputation previousComputation
        @_trackerInstance.inCompute = previousInCompute

  _compute: ->
    FiberUtils.synchronize guard, @_id, =>
      @invalidated = false

      @_runInside (computation) =>
        while @_beforeRunCallbacks.length
          callback = @_beforeRunCallbacks.shift()
          Tracker.nonreactive =>
            callback @

        @_func.call null, @

        while @_afterRunCallbacks.length
          callback = @_afterRunCallbacks.shift()
          Tracker.nonreactive =>
            callback @

  _needsRecompute: ->
    @invalidated and not @stopped

  _recompute: ->
    FiberUtils.synchronize guard, @_id, =>
      assert not @_recomputing
      @_recomputing = true
      try
        if @_needsRecompute()
          @_compute()
      finally
        @_recomputing = false

  flush: ->
    FiberUtils.ensure =>
      return if @_recomputing

      @_recompute()

  run: ->
    FiberUtils.ensure =>
      @invalidate()
      @flush()

class Tracker.Dependency
  constructor: ->
    @_dependentsById = {}

  depend: (computation) ->
    unless computation
      return false unless Tracker.active
      computation = Tracker.currentComputation

    id = computation._id

    if id not of @_dependentsById
      @_dependentsById[id] = computation
      computation.onInvalidate =>
        delete @_dependentsById[id]
      return true

    false

  changed: ->
    for id, computation of @_dependentsById
      computation.invalidate()

  hasDependents: ->
    for id, computation of @_dependentsById
      return true
    false

export {Tracker}
