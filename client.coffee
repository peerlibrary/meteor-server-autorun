# We patch client side as well so that they have the same API.
# See https://github.com/meteor/meteor/pull/4710
unless Tracker.Computation::flush
  Tracker.Computation::flush = ->
    return if @_recomputing

    @_recompute()

unless Tracker.Computation::run
  Tracker.Computation::run = ->
    @invalidate()
    @flush()
