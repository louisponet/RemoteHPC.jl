module Schedulers
    using JSON3
    using ..RemoteHPC
    
    abstract type Scheduler end

    submit(::S, ::String) where {S<:Scheduler} = error("No submit method defined for $S.")
    abort(::S, ::Int)     where {S<:Scheduler} = error("No abort method defined for $S.")
    jobstate(::S, ::Any)  where {S<:Scheduler} = error("No jobstate method defined for $S.")
    
    function queue!(q, s::Scheduler, init)
        if init
            if ispath(QUEUE_FILE)
                copy!(q, JSON3.read(read(QUEUE_FILE), Dict{String, Tuple{Int, JobState}}))
            end
        end
        for (dir, info) in q
            if !isdir(dir)
                pop!(q, dir)
                continue
            end
            id = info[1]
            if info[2] in (Running, Pending, Submitted, Unknown)
                q[dir] = (id, jobstate(s, id))
            end
        end
        JSON3.write(QUEUE_FILE, q)
        return q
    end

    ## BASH ##
    struct Bash <: Scheduler end
        
    function jobstate(::Bash, id::Int)
        out = Pipe()
        err = Pipe()
        p = run(pipeline(ignorestatus(`ps -p $id`), stderr = err, stdout=out))
        close(out.in)
        close(err.in)
        return p.exitcode == 1 ? Jobs.Completed : Jobs.Running
    end

    submit(::Bash, j::String) = 
        Int(getpid(run(Cmd(`bash job.tt`, detach=true, dir=j), wait=false)))

    abort(::Bash, id::Int) = 
        run(`pkill $id`)
    

    ### Slurm ##
    struct Slurm <: Scheduler end
        
    function jobstate(::Slurm, id::Int)
        cmd = `sacct -u $(ENV["USER"]) --format=State -j $id -P`
        state = readlines(cmd)[2]
        if state == "PENDING"
            return Pending
        elseif state == "RUNNING"
            return Running
        elseif state == "COMPLETED"
            return Completed
        elseif state == "CANCELLED"
            return Cancelled
        elseif state == "BOOT_FAIL"
            return BootFail
        elseif state == "DEADLINE"
            return Deadline
        elseif state == "FAILED"
            return Failed
        elseif state == "NODE_FAIL"
            return NodeFail
        elseif state == "OUT_OF_MEMORY"
            return OutOfMemory
        elseif state == "PREEMTED"
            return Preempted
        elseif state == "REQUEUED"
            return Requeued
        elseif state == "RESIZING"
            return Resizing
        elseif state == "REVOKED"
            return Revoked
        elseif state == "SUSPENDED"
            return Suspended
        elseif state == "TIMEOUT"
            return Timeout
        end
        return Unknown
    end

    submit(::Slurm, j::String) =
        parse(Int, split(read(Cmd(`sbatch job.tt`, dir=j), String))[end])

    abort(::Slurm, id::Int) = 
        run(`scancel $id`)


    
end
