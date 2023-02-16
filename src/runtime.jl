mutable struct Job
    id::Int
    state::JobState
end

Base.@kwdef mutable struct QueueInfo
    full_queue::Dict{String,Job} = Dict{String,Job}()
    current_queue::Dict{String,Job} = Dict{String,Job}()
    submit_queue::PriorityQueue{String, Tuple{Int, Float64}} = PriorityQueue{String, Tuple{Int, Float64}}(Base.Order.Reverse)
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
        log_error(e, logtype=RuntimeLog)
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
                # TODO: should be deprecated
                tq = JSON3.read(t)
                lock(qu) do q
                    q.full_queue = StructTypes.constructfrom(Dict{String,Job}, tq[:full_queue])
                    q.current_queue = StructTypes.constructfrom(Dict{String, Job}, tq[:current_queue])
                    if tq[:submit_queue] isa AbstractArray
                        for jdir in tq[:submit_queue]
                            q.submit_queue[jdir] = DEFAULT_PRIORITY
                            q.full_queue[jdir].state = Submitted
                        end
                    else
                        for (jdir, priority) in tq[:submit_queue]
                            if length(priority) > 1
                                q.submit_queue[string(jdir)] = (priority...,)
                            else
                                q.submit_queue[string(jdir)] = (priority, -time())
                            end
                        end
                    end
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
                    q.submit_queue[d] = (DEFAULT_PRIORITY, -time())
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

Base.@kwdef mutable struct ServerData
    server::Server
    total_requests::Int = 0
    current_requests::Int = 0
    t::Float64 = time()
    requests_per_second::Float64 = 0.0
    total_job_submissions::Int = 0
    submit_channel::Channel{Pair{String, Tuple{Int, Float64}}} = Channel{Pair{String, Tuple{Int, Float64}}}(Inf)
    queue::Queue = Queue()
    sleep_time::Float64 = 5.0
    connections::Dict{String, Bool} = Dict{String, Bool}()
    stop::Bool = false
    lock::ReentrantLock = ReentrantLock()
end


const SLEEP_TIME = Ref(5.0)

function main_loop(s::ServerData)
    fill!(s.queue, s.server.scheduler, true)
    # Used to identify if multiple servers are running in order to selfdestruct 
    # log_mtimes = mtime.(joinpath.((config_path("logs/runtimes/"),), readdir(config_path("logs/runtimes/"))))
    t = Threads.@spawn while !s.stop
        try
            fill!(s.queue, s.server.scheduler, false)
            JSON3.write(config_path("jobs", "queue.json"), s.queue.info)
        catch e
            log_error(e, logtype = RuntimeLog)
        end
        sleep(s.sleep_time)
    end
    Threads.@spawn while !s.stop
        try
            handle_job_submission!(s)
        catch e
            log_error(e, logtype = RuntimeLog)
        end
        sleep(s.sleep_time)
    end
    while !s.stop
        # monitor_issues(log_mtimes)
        try
            log_info(s)
        catch e
            log_error(e, logtype = RuntimeLog)
        end
        if ispath(config_path("self_destruct"))
            @debug "self_destruct found, self destructing..."
            exit()
        end
        sleep(s.sleep_time)
    end
    fetch(t)
    return JSON3.write(config_path("jobs", "queue.json"), s.queue.info)
end

function log_info(s::ServerData)
    dt = time() - s.t
    lock(s.lock)
    curreq = s.current_requests
    s.current_requests = 0
    s.t = time()
    unlock(s.lock)
    s.requests_per_second = curreq / dt
    s.total_requests += curreq
    
    @debugv 0 "current_queue: $(length(s.queue.info.current_queue)) - submit_queue: $(length(s.queue.info.submit_queue))" logtype=RuntimeLog
    @debugv 0 "total requests: $(s.total_requests) - r/s: $(s.requests_per_second)" logtype=RESTLog 
end


function monitor_issues(log_mtimes)
    # new_mtimes = mtime.(joinpath.((config_path("logs/runtimes"),),
    #                               readdir(config_path("logs/runtimes"))))
    # if length(new_mtimes) != length(log_mtimes)
    #     @error "More Server logs got created signalling a server was started while a previous was running." logtype=RuntimeLog
    #     touch(config_path("self_destruct"))
    # end
    # ndiff = length(filter(x -> log_mtimes[x] != new_mtimes[x], 1:length(log_mtimes)))
    # if ndiff > 1
    #     @error "More Server logs modification times differed than 1." logtype=RuntimeLog
    #     touch(config_path("self_destruct"))
    # end
end

function handle_job_submission!(s::ServerData)
    @debugv 2 "Submitting jobs" logtype=RuntimeLog
    to_submit = s.queue.info.submit_queue
    njobs = length(s.queue.info.current_queue)
    while !isempty(s.submit_channel)
        jobdir,priority = take!(s.submit_channel)
        to_submit[jobdir] = priority
    end
    n_submit = min(s.server.max_concurrent_jobs - njobs, length(to_submit))
    submitted = 0
    for i in 1:n_submit
        job_dir, priority = dequeue_pair!(to_submit)
        if ispath(job_dir)
            curtries = 0
            while -1 < curtries < 3
                try
                    id = submit(s.server.scheduler, job_dir)
                    @debugv 2 "Submitting Job: $(id)@$(job_dir)" logtype=RuntimeLog
                    lock(s.queue) do q
                        return q.current_queue[job_dir] = Job(id, Pending)
                    end
                    curtries = -1
                    submitted += 1
                catch e
                    curtries += 1
                    sleep(s.sleep_time)
                    lock(s.queue) do q
                        q.full_queue[job_dir] = Job(-1, SubmissionError)
                    end
                    
                    with_logger(FileLogger(joinpath(job_dir, "submission.err"), append=true)) do
                        log_error(e)
                    end
                end
            end
            if curtries != -1
                to_submit[job_dir] = (priority[1] - 1, priority[2])
            end
        else
            @warnv 2 "Submission job at dir: $job_dir is not a directory." logtype=RuntimeLog
        end
    end
    @debugv 2 "Submitted $submitted jobs" logtype=RuntimeLog
end

function requestHandler(handler, s::ServerData)
    return function f(req)
        start = Dates.now()
        @debugv 2 "BEGIN - $(req.method) - $(req.target)" logtype=RESTLog
        resp = HTTP.Response(404)
        try
            obj = handler(req)
            if obj === nothing
                resp = HTTP.Response(204)
            elseif obj isa HTTP.Response
                return obj
            elseif obj isa Exception
                resp = HTTP.Response(500, log_error(obj))
            else
                resp = HTTP.Response(200, JSON3.write(obj))
            end
        catch e
            resp = HTTP.Response(500, log_error(e))
        end
        stop = Dates.now()
        @debugv 2 "END - $(req.method) - $(req.target) - $(resp.status) - $(Dates.value(stop - start)) - $(length(resp.body))" logtype=RESTLog
        lock(s.lock)
        s.current_requests += 1
        unlock(s.lock)
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
                while !istaskdone(t)
                    yield()
                end
                return fetch(t)
            end
        end
        return HTTP.Response(401, "unauthorized")
    end
end

function check_connections!(connections, verify_tunnels; names=keys(connections))
    for (n, connected) in connections
        if !exists(Server(name=n))
            pop!(connections, n)
            continue
        end
        !(n in names) && continue
        s = load(Server(n))
        s.domain == "localhost" && continue
        
        try
            connections[n] = HTTP.get(s, URI(path="/isalive")) !== nothing
        catch
            connections[n] = false
        end
        @debugv 1 "Connection to $n: $(connections[n])" logtype=RuntimeLog
    end
    if verify_tunnels
        @debugv 1 "Verifying tunnels" logtype=RuntimeLog
        for (n, connected) in connections
            connected && continue
            !(n in names) && continue
            s = load(Server(n))
            s.domain == "localhost" && continue
            
            connections[n] = @timeout 30 begin 
                destroy_tunnel(s)
                try
                    remote_server = load_config(s.username, s.domain, config_path(s))
                    remote_server === nothing && return false
                    s.port = construct_tunnel(s, remote_server.port)
                    sleep(2)
                    s.uuid = remote_server.uuid
                    try
                        
                        HTTP.get(s, URI(path="/isalive")) !== nothing
                        save(s)
                        @debugv 1 "Connected to $n" logtype=RuntimeLog
                        return true
                    catch
                        destroy_tunnel(s)
                        return false
                    end
                catch err
                    log_error(err, logtype=RuntimeLog)
                    destroy_tunnel(s)
                    return false
                end
            end false
        end
    end
    return connections
end

function check_connections!(server_data::ServerData, args...; kwargs...)
    all_servers = load(Server(""))
    for k in filter(x-> !(x in all_servers), keys(server_data.connections))
        delete!(server_data.connections, k)
    end
    for n in all_servers
        n == server_data.server.name && continue
        server_data.connections[n] = get(server_data.connections, n, false)
    end
    conn = check_connections!(server_data.connections, args...; kwargs...)
    @debugv 1 "Connections: $(server_data.connections)" logtype=RuntimeLog
    return conn
end
    
function julia_main(;verbose=0)::Cint
    logger = TimestampLogger(TeeLogger(HTTPLogger(),
                                   NotHTTPLogger(TeeLogger(RESTLogger(),
                                                 RuntimeLogger(),
                                                 GenericLogger()))))
    with_logger(logger) do
        LoggingExtras.withlevel(LoggingExtras.Debug; verbosity=verbose) do
            try
                s = local_server()
                port, server = listenany(ip"0.0.0.0", 8080)
                s.port = port

                server_data = ServerData(server=s)

                @debug "Checking connections..." logtype=RuntimeLog
                check_connections!(server_data, false)

                @debug "Setting up Router" logtype=RuntimeLog

                setup_core_api!(server_data)
                setup_job_api!(server_data)
                setup_database_api!()
                repeat = router("/repeat", interval=1.0, tags=["repeat"])
                @get repeat("/check_connections") () -> check_connections!(server_data, false)
                
                @debug "Starting main loop" logtype=RuntimeLog

                t = Threads.@spawn try
                    main_loop(server_data)
                catch e
                    log_error(e, logtype=RuntimeLog)
                end
                @debug "Starting RESTAPI - HOST $(gethostname()) - USER $(get(ENV, "USER", "unknown_user"))" logtype=RuntimeLog 
                save(s)
                @async serve(middleware = [x -> requestHandler(x, server_data), x -> AuthHandler(x, UUID(s.uuid))],
                                  host="0.0.0.0", port=Int(port), server = server, access_log=nothing, serialize=false)
                while !server_data.stop
                    sleep(1)
                end
                @debug "Shutting down server"
                terminate()
                fetch(t)
                return 0
            catch e
                log_error(e)
                rethrow(e)
            end
        end
    end
end
