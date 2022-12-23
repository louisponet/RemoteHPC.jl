@enum LogType RESTLog RuntimeLog  

const LOGGING_DATE_FORMAT = "yyyy-mm-dd HH:MM:SS"

# Logs an error with nice stacktrace
function log_error(e; kwargs...)
    s = IOBuffer()
    showerror(s, e, catch_backtrace(); backtrace=true)
    errormsg = String(resize!(s.data, s.size))
    @error errormsg kwargs...
    return errormsg
end

# Different simple Loggers
LevelLogger(logger, level) = EarlyFilteredLogger(logger) do log
    log.level == level
end

function TimestampLogger(logger)
    TransformerLogger(logger) do log
        merge(log, (;message="[$(Dates.format(now(), LOGGING_DATE_FORMAT))] {tid: $(Threads.threadid())} - $(log.message)"))
    end
end

mutable struct TimeBufferedFileLogger <: AbstractLogger
    path::String
    buffer::IOBuffer
    interval::Float64
    last_write::Float64
end

TimeBufferedFileLogger(p::String; interval = 10.0) = TimeBufferedFileLogger(p, IOBuffer(), interval, 0.0)
    
function Logging.handle_message(logger::TimeBufferedFileLogger, level::LogLevel, message, _module, group, id,
                        filepath, line; kwargs...)
    @nospecialize
    iob = IOContext(logger.buffer, :compact => true)
    msglines = eachsplit(chomp(convert(String, string(message))::String), '\n')
    msg1, rest = Iterators.peel(msglines)
    println(iob, msg1)
    for msg in rest
        println(iob, "  ", msg)
    end
    curt = time()
    dt = curt - logger.last_write
    if dt > logger.interval
        open(logger.path, append = true) do f
            write(f, take!(logger.buffer))
        end
        logger.last_write = curt
    end
end
LoggingExtras.min_enabled_level(::TimeBufferedFileLogger) = BelowMinLevel
LoggingExtras.shouldlog(::TimeBufferedFileLogger, args...) = true
LoggingExtras.catch_exceptions(filelogger::TimeBufferedFileLogger) = false

function RESTLogger()
    test(log) = get(log.kwargs, :logtype, nothing) == RESTLog
    tlogger = TransformerLogger(TimeBufferedFileLogger(config_path("logs/restapi.log"))) do log
        return merge(log, (;kwargs=()))
    end
    return ActiveFilteredLogger(test, tlogger)
end

function RuntimeLogger()
    test(log) = get(log.kwargs, :logtype, nothing) == RuntimeLog
    tlogger = TransformerLogger(TimeBufferedFileLogger(config_path("logs/runtime.log"))) do log
        return merge(log, (;kwargs=()))
    end
    return ActiveFilteredLogger(test, tlogger)
end

function GenericLogger()
    return ActiveFilteredLogger(TimeBufferedFileLogger(config_path("logs/errors.log"))) do log
        return get(log.kwargs, :logtype, nothing) === nothing
    end
end

function HTTPLogger()
    return EarlyFilteredLogger(TimeBufferedFileLogger(config_path("logs/HTTP.log"))) do log
        return log._module === HTTP || parentmodule(log._module) === HTTP
    end
end
function NotHTTPLogger(logger)
    return EarlyFilteredLogger(logger) do log
        return log._module !== HTTP && parentmodule(log._module) !== HTTP
    end
end
