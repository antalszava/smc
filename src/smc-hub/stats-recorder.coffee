###############################################################################
#
# SageMathCloud: A collaborative web-based interface to Sage, IPython, LaTeX and the Terminal.
#
#    Copyright (C) 2016, SageMath, Inc.
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
###############################################################################

# This is a small helper class to record real-time statistics and metrics
# It is designed for the hub, such that a local process can easily check its health.
# it uses a status file to store the metrics -- TODO: also push this to the DB
# usage: after init, publish key/value pairs which are then going to be reported

fs         = require('fs')
underscore = require('underscore')


# some constants
FREQ_s     = 5    # write stats every FREQ seconds
DELAY_s    = 5    # with this DELAY seconds initial delay
DISC_LEN   = 5    # length of queue for recording discrete values
MAX_BUFFER = 1000 # size of buffered values, which is cleared in the @_update step

# exponential smoothing, based on linux's load 1-exp(-1) smoothing
# with compensation for sampling time FREQ_s
d = 1 - Math.pow(Math.exp(-1), FREQ_s / 60)
DECAY = [d, Math.pow(d, 5), Math.pow(d, 15)]


# there is more than just continuous values
# cont: continuous (like number of changefeeds), will be smoothed
#       disc: discrete, like blocked, will be recorded with timestamp
#             in a queue of length DISC_LEN
exports.TYPE = TYPE =
    LAST : 'last'       # only the most recent value is recorded
    DISC : 'discrete'   # timeseries of length DISC_LEN
    CONT : 'continuous' # continuous with exponential decay
    MAX  : 'contmax'    # like CONT, reduces buffer to max value
    SUM  : 'contsum'    # like CONT, reduces buffer to sum of values divided by FREQ_s


class exports.StatsRecorder
    constructor: (@filename, @dbg, cb) ->
        ###
        * @filename: if set, periodically saved there. otherwise use @get.
        * @dbg: e.g. reporting via winston or whatever
        ###
        # stores the current state of the statistics
        @_stats = {}
        @_types = {} # key → TYPE.T mapping

        # the full statistic
        @_data  = {}

        # start of periodically calling publish/update
        setTimeout((=> setInterval(@_publish, FREQ_s * 1000)), DELAY_s * 1000)
        # record start time (as string!)
        @record("start", new Date(), TYPE.LAST)

        # initialization finished
        cb?()

    # every FREQ_s the _data dict is being updated
    # e.g current value, exp decay, later on also "intelligent" min/max, etc.
    _update : ->
        smooth = (new_value, arr) ->
            arr ?= []
            arr[0] = new_value
            # compute smoothed value sval for each decay param
            for d, idx in DECAY
                sval = arr[idx + 1] ? new_value
                sval = d * new_value + (1-d) * sval
                arr[idx + 1] = sval
            return arr

        for key, value of @_stats
            switch @_types[key]
                when TYPE.CONT, TYPE.MAX
                    # exponential smoothing, either update with newest value
                    # or use the latest one
                    if not value?
                        [..., value] = @_data[key]
                        # in case DATA[key] is empty
                        if not value?
                            continue
                    @_data[key] = smooth(value, @_data[key])
                when TYPE.SUM
                    if not value?
                        [..., value] = @_data[key]
                        # in case DATA[key] is empty
                        if not value?
                            continue
                    sum = underscore.reduce(value, ((a, b) -> a+b), 0)
                    sum /= FREQ_s # to get a per 1s value!
                    @_data[key] = smooth(sum, @_data[key])
                when TYPE.DISC
                    # this is [timestamp, discrete value]
                    if not value?
                        continue
                    queue = @_data[key] ? []
                    @_data[key] = [queue..., value...][-DISC_LEN..]
                when TYPE.LAST
                    # ... just store it
                    if not value?
                        continue
                    @_data[key] = value
            # we've consumed the value(s), reset them
            @_stats[key] = null

    # the periodically called publication step
    _publish : (cb) =>
        @record("now", new Date(), TYPE.LAST)
        # also record system metrics like cpu, memory, ... ?
        @_update()
        # only if we have a @filename, save it there
        if @filename?
            json = JSON.stringify(@_data, null, 2)
            fs.writeFile(@filename, json, cb?())

    record : (key, value, type = TYPE.CONT) =>
        if (@_types[key] ? type) != type
            @dbg("WARNING: you are switching types from #{@_types[key]} to #{type} -- IGNORED")
            return
        @_types[key] = type
        switch type
            when TYPE.LAST
                @_stats[key] = value
            when TYPE.CONT
                # before getting cleared by @_update, it reduces multiple recorded values to the maximum
                # TODO make this more intelligent.
                current = @_stats[key] ? Number.NEGATIVE_INFINITY
                @_stats[key] = Math.max(value, current)
            when TYPE.SUM
                arr = @_stats[key] ? []
                @_stats[key] = [arr..., value][-MAX_BUFFER..]
            when TYPE.MAX
                current = @_stats[key] ? Number.NEGATIVE_INFINITY
                @_stats[key] = Math.max(value, current)
            when TYPE.DISC
                ts = (new Date()).toISOString()
                arr = @_stats[key] ? []
                @_stats[key] = [arr..., [ts, value]][-MAX_BUFFER..]
            else
                @dbg?('hub/record_stats: unknown or undefined type #{type}')