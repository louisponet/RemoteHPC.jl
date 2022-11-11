mutable struct Job
    id::Int
    state::JobState
end

Base.@kwdef mutable struct QueueInfo
    full_queue::Dict{String,Job} = Dict{String,Job}()
    current_queue::Dict{String,Job} = Dict{String,Job}()
    submit_queue::Vector{String} = String[]
end
StructTypes.StructType(::Type{QueueInfo}) = StructTypes.Mutable()

struct Queue
    lock::ReentrantLock
    info::QueueInfo
end
Queue() = Queue(ReentrantLock(), QueueInfo())

function Base.lock(f::Function, q::Queue)
    lock(q.lock)
    try
        f(q.info)
    catch e
        rethrow(e)
    finally
        unlock(q.lock)
    end
end

function Base.fill!(qu::Queue, s::Scheduler, init)
    qfile = config_path("jobs", "queue.json")
    if init
        if ispath(qfile)
            t = read(qfile)
            if !isempty(t)
                tq = JSON3.read(t, QueueInfo)
                lock(qu) do q
                    copy!(q.full_queue, tq.full_queue)
                    copy!(q.current_queue, tq.current_queue)
                    return copy!(q.submit_queue, tq.submit_queue)
                end
            end
        end
    end
    lock(qu) do q
        for q_ in (q.full_queue, q.current_queue)
            for (dir, info) in q_
                if !ispath(joinpath(dir, "job.sh"))
                    delete!(q_, dir)
                end
            end
        end
    end
    # Here we check whether the scheduler died while the server was running and try to restart and resubmit   
    if maybe_scheduler_restart(s)
        lock(qu) do q
            for (d, i) in q.current_queue
                if ispath(joinpath(d, "job.sh"))
                    q.full_queue[d] = Job(-1, Saved)
                    push!(q.submit_queue, d)
                end
                pop!(q.current_queue, d)
            end
        end
    else
        squeue = queue(s)
        lock(qu) do q
            for (d, i) in q.current_queue
                if haskey(squeue, d)
                    state = pop!(squeue, d)[2]
                else
                    state = jobstate(s, i.id)
                end
                if in_queue(state)
                    delete!(q.full_queue, d)
                    q.current_queue[d] = Job(i.id, state)
                else
                    delete!(q.current_queue, d)
                    q.full_queue[d] = Job(i.id, state)
                end
            end
            for (k, v) in squeue
                q.current_queue[k] = Job(v...)
            end
        end
    end
    return qu
end

function main_loop(s::Server, submit_channel, queue, main_loop_stop)
    fill!(queue, s.scheduler, true)
    @info (timestamp = string(Dates.now()), username = get(ENV, "USER", "nouser"),
           host = gethostname(), pid = getpid())

    # Used to identify if multiple servers are running in order to selfdestruct 
    log_mtimes = mtime.(joinpath.((config_path("logs/runtimes/"),),
                                  readdir(config_path("logs/runtimes/"))))
    t = Threads.@spawn while !main_loop_stop[]
        try
            fill!(queue, s.scheduler, false)
            JSON3.write(config_path("jobs", "queue.json"), queue.info)
        catch e
            @error "Queue error:" e stacktrace(catch_backtrace())
        end
        sleep(5)
    end
    Threads.@spawn while !main_loop_stop[]
        try
            handle_job_submission!(queue, s, submit_channel)
        catch e
            @error "Job submission error:" e stacktrace(catch_backtrace())
        end
        sleep(5)
    end
    Threads.@spawn while !main_loop_stop[]
        monitor_issues(log_mtimes)

        try
            print_log(queue)
        catch
            @error "Logging error:" e stacktrace(catch_backtrace())
        end
        if ispath(config_path("self_destruct"))
            @info (timestamp = Dates.now(),
                   message = "self_destruct found, self destructing...")
            exit()
        end
        sleep(5)
    end
    fetch(t)
    return JSON3.write(config_path("jobs", "queue.json"), queue.info)
end

function print_log(queue)
    # @info (timestamp = string(Dates.now()), njobs = length(queue.current_queue), nprocs = nprocs)
end

function monitor_issues(log_mtimes)
    new_mtimes = mtime.(joinpath.((config_path("logs/runtimes"),),
                                  readdir(config_path("logs/runtimes"))))
    if length(new_mtimes) != length(log_mtimes)
        @error "More Server logs got created signalling a server was started while a previous was running."
        touch(config_path("self_destruct"))
    end
    ndiff = length(filter(x -> log_mtimes[x] != new_mtimes[x], 1:length(log_mtimes)))
    if ndiff > 1
        @error "More Server logs modification times differed than 1."
        touch(config_path("self_destruct"))
    end
    daemon_log = config_path("logs/daemon/restapi.log")
    if filesize(daemon_log) > 1e9
        open(daemon_log, "w") do f
            return write(f, "")
        end
    end
end

function handle_job_submission!(queue, s::Server, submit_channel)
    job_dirs = queue.info.submit_queue
    njobs = length(queue.info.current_queue)
    while !isempty(submit_channel)
        push!(job_dirs, take!(submit_channel))
    end
    n_submit = min(s.max_concurrent_jobs - njobs, length(job_dirs))
    for i in 1:n_submit
        job_dir = job_dirs[i]
        if ispath(job_dir)
            curtries = 0
            while -1 < curtries < 3
                try
                    id = submit(s.scheduler, job_dir)
                    @info (string(Dates.now()), job_dir, id, Pending)
                    lock(queue) do q
                        return q.current_queue[job_dir] = Job(id, Pending)
                    end
                    curtries = -1
                catch e
                    curtries += 1
                    sleep(5)
                    with_logger(FileLogger(joinpath(job_dir, "submission.err"), append=true)) do
                        @error e
                    end
                end
            end
            if curtries != -1
                push!(job_dirs, job_dir)
            end
        else
            @warn "Submission job at dir: $job_dir is not a directory."
        end
    end
    return deleteat!(job_dirs, 1:n_submit)
end

function server_logger()
    p = config_path("logs/runtimes")
    mkpath(p)
    serverid = length(readdir(p)) + 1
    return FileLogger(config_path(joinpath(p, "$serverid.log")); append = false)
end

function restapi_logger()
    p = config_path("logs/daemon")
    mkpath(p)
    return FileLogger(joinpath(p, "restapi.log"); append = false)
end
function job_logger(id::Int)
    p = config_path("logs/jobs")
    mkpath(p)
    return FileLogger(joinpath(p, "$id.log"))
end

function requestHandler(handler)
    return function f(req)
        start = Dates.now()
        @info (timestamp = string(start), event = "Begin", tid = Threads.threadid(),
               method = req.method, target = req.target)
        local resp
        try
            obj = handler(req)
            if obj === nothing
                resp = HTTP.Response(204)
            elseif obj isa HTTP.Response
                return obj
            else
                resp = HTTP.Response(200, JSON3.write(obj))
            end
        catch e
            s = IOBuffer()
            showerror(s, e, catch_backtrace(); backtrace = true)
            errormsg = String(resize!(s.data, s.size))
            @error errormsg
            resp = HTTP.Response(500, errormsg)
        end
        stop = Dates.now()
        @info (timestamp = string(stop), event = "End", tid = Threads.threadid(),
               method = req.method, target = req.target,
               duration = Dates.value(stop - start),
               status = resp.status, bodysize = length(resp.body))
        return resp
    end
end

function AuthHandler(handler, user_uuid::UUID)
    return function f(req)
        if HTTP.hasheader(req, "USER-UUID")
            uuid = HTTP.header(req, "USER-UUID")
            if UUID(uuid) == user_uuid
                t = ThreadPools.spawnbg() do
                    return handler(req)
                end
                return fetch(t)
            end
        end
        return HTTP.Response(401, "unauthorized")
    end
end

function check_connections!(connections)
    for n in keys(connections)
        s = load(Server(n))
        @info "Checking $n connectivity."
        tsk = Threads.@spawn try
            return HTTP.get(s, URI(path="/isalive"); connect_timeout = 2, retries = 2)  !== nothing
        catch
            t = find_tunnel(s)
            if t === nothing
                # Tunnel was dead -> create one and try again
                try
                    remote_server = load_config(s.username, s.domain)
                    remote_server === nothing && return false
                    s.port = construct_tunnel(s, remote_server.port)
                    sleep(2)
                    s.uuid = remote_server.uuid
                    try
                        if HTTP.get(s, URI(path="/isalive"); connect_timeout = 2, retries = 2) !== nothing
                            save(s)
                            return true
                        end
                    catch
                        # Still no connection -> destroy tunnel because server dead
                        destroy_tunnel(s)
                        return false
                    end
                catch
                    destroy_tunnel(s)
                    return false
                end
            else
                # Tunnel existed but no connection -> server dead
                destroy_tunnel(s)
                return false
            end
        end
        retries = 0
        while !istaskdone(tsk) && retries < 300
            sleep(0.1)
            retries += 1
        end
        if retries == 300
            destroy_tunnel(s)
            try
                Base.throwto(tsk, InterruptException())
            catch
                nothing
            end
            if connections[n]
                @info now(), "Lost connection to $n."
            end
            connections[n] = false
        elseif istaskfailed(tsk)
            destroy_tunnel(s)
            if connections[n]
                @info now(), "Lost connection to $n."
            end
            connections[n] = false
        else
            connection = fetch(tsk)
            if connection != connections[n]
                @info now(), "Connected to $n."
            end
            connections[n] = connection
        end
    end
        
end

function julia_main()::Cint
    # initialize_config_dir()
    s = local_server()
    port, server = listenany(ip"0.0.0.0", 8080)
    s.port = port
    user_uuid = UUID(s.uuid)

    logger = server_logger()

    should_stop = Ref(false)
    connections = Dict{String, Bool}([n => false for n in load(Server(""))])
    pop!(connections, s.name)
    connections_task = @tspawnat min(Threads.nthreads(), 3) with_logger(logger)  do
        while !should_stop[]
            try
                for n in load(Server(""))
                    if !haskey(connections, n)
                        connections[n] = false
                    end
                end
                check_connections!(connections)
            catch e
                @error e, stacktrace(catch_backtrace())
            end
            sleep(1)
        end
    end


    router = HTTP.Router()
    submit_channel = Channel{String}(Inf)
    job_queue = Queue()
    setup_core_api!(router, s, connections)
    setup_job_api!(router, submit_channel, job_queue, s.scheduler)
    setup_database_api!(router)

    HTTP.register!(router, "GET", "/server/config", (req) -> s)

    t = @tspawnat min(Threads.nthreads(), 2) with_logger(logger) do
        try
            main_loop(s, submit_channel, job_queue, should_stop)
        catch e
            @error e, stacktrace(catch_backtrace())
        end
    end
    HTTP.register!(router, "PUT", "/server/kill",
                   (req) -> (should_stop[] = true; true))
    save(s)
    with_logger(restapi_logger()) do
        @info (timestamp = string(Dates.now()), username = ENV["USER"],
               host = gethostname(), pid = getpid(), port = port)

        @async HTTP.serve(router |> requestHandler |> x -> AuthHandler(x, user_uuid),
                          "0.0.0.0", port, server = server)
        while !should_stop[]
            sleep(1)
        end
    end
    fetch(t)
    fetch(connections_task)
    close(server)
    return 0
end
