function suppress(f::Function)
    with_logger(FileLogger("/dev/null")) do
        return f()
    end
end

struct StallException <: Exception
    e
end

function Base.showerror(io::IO, err::StallException, args...)
    print(io, "StallException:")
    showerror(io, err.e, args...)
end

macro timeout(seconds, expr, err_expr=:(nothing))
    esc(quote
        tsk__ = @task $expr
        schedule(tsk__)
        Base.Timer($seconds) do timer__
            tsk__ !== nothing && (istaskdone(tsk__) || Base.throwto(tsk__, InterruptException()))
        end
        try
            fetch(tsk__)
        catch err__
            if err__.task.exception isa InterruptException
                RemoteHPC.log_error(RemoteHPC.StallException(err__))
                $err_expr
            else
                rethrow(err__.task.exception)
            end
        end
    end)
end
