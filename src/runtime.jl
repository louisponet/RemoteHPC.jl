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

Base.@kwdef mutable struct ServerData
    server::Server
    total_requests::Int = 0
    current_requests::Int = 0
    t::Float64 = time()
    requests_per_second::Float64 = 0.0
    total_job_submissions::Int = 0
    submit_channel::Channel{String} = Channel{String}(Inf)
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
    Threads.@spawn while !s.stop
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
    job_dirs = s.queue.info.submit_queue
    njobs = length(s.queue.info.current_queue)
    while !isempty(s.submit_channel)
        push!(job_dirs, take!(s.submit_channel))
    end
    n_submit = min(s.server.max_concurrent_jobs - njobs, length(job_dirs))
    for i in 1:n_submit
        job_dir = job_dirs[i]
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
                catch e
                    curtries += 1
                    sleep(s.sleep_time)
                    with_logger(FileLogger(joinpath(job_dir, "submission.err"), append=true)) do
                        log_error(e)
                    end
                end
            end
            if curtries != -1
                push!(job_dirs, job_dir)
            end
        else
            @warnv 2 "Submission job at dir: $job_dir is not a directory." logtype=RuntimeLog
        end
    end
    return deleteat!(job_dirs, 1:n_submit)
end

function requestHandler(handler, s::ServerData)
    return function f(req)
        start = Dates.now()
        @debugv 2 "BEGIN - $(req.method) - $(req.target)" logtype=RESTLog
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
                return fetch(t)
            end
        end
        return HTTP.Response(401, "unauthorized")
    end
end

function check_connections!(connections)
    for n in keys(connections)
        !exists(Server(name=n)) && continue
        s = load(Server(n))
        if s.domain == "localhost"
            continue
        end
        @debugv 1 "Checking $n connectivity." logtype=RuntimeLog
        tsk = Threads.@spawn try
            return HTTP.get(s, URI(path="/isalive"))  !== nothing
        catch
            t = find_tunnel(s)
            if t === nothing
                # Tunnel was dead -> create one and try again
                try
                    remote_server = load_config(s.username, s.domain, config_path(s))
                    remote_server === nothing && return false
                    s.port = construct_tunnel(s, remote_server.port)
                    sleep(2)
                    s.uuid = remote_server.uuid
                    try
                        if HTTP.get(s, URI(path="/isalive")) !== nothing
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
                @debugv 1 "Lost connection to $n." logtype=RuntimeLog
            end
            connections[n] = false
        elseif istaskfailed(tsk)
            destroy_tunnel(s)
            if connections[n]
                @debugv 1 "Lost connection to $n." logtype=RuntimeLog
            end
            connections[n] = false
        else
            connection = fetch(tsk)
            if connection != connections[n]
                @debugv 1 "Connected to $n." logtype=RuntimeLog
            end
            connections[n] = connection
        end
    end
    return connections
end

function check_connections!(server_data::ServerData)
    all_servers = load(Server(""))
    for k in filter(x-> !(x in all_servers), keys(server_data.connections))
        delete!(server_data.connections, k)
    end
    for n in all_servers
        n == server_data.server.name && continue
        server_data.connections[n] = get(server_data.connections, n, false)
    end
    conn = check_connections!(server_data.connections)
    @debugv 0 "Connections: $(server_data.connections)" logtype=RuntimeLog
    return conn
end
    
function julia_main(;verbose=0)::Cint
    logger = TimestampLogger(TeeLogger(HTTPLogger(),
                                       NotHTTPLogger(TeeLogger(RESTLogger(),
                                                     RuntimeLogger(),
                                                     GenericLogger()))))
    with_logger(logger) do
        LoggingExtras.withlevel(Debug; verbosity=verbose) do
            try
                # initialize_config_dir()
                s = local_server()
                port, server = listenany(ip"0.0.0.0", 8080)
                s.port = port

                server_data = ServerData(server=s)

                @debug "Checking connections..." logtype=RuntimeLog
                check_connections!(server_data)

                @debug "Setting up Router" logtype=RuntimeLog

                router = HTTP.Router()
                setup_core_api!(router, server_data)
                setup_job_api!(router, server_data)
                setup_database_api!(router)
                
                @debug "Starting main loop" logtype=RuntimeLog

                t = @tspawnat min(Threads.nthreads(), 2) try
                    main_loop(server_data)
                catch e
                    log_error(e, logtype=RuntimeLog)
                end
                @debug "Starting RESTAPI - HOST $(gethostname()) - USER $(get(ENV, "USER", "unknown_user"))" logtype=RuntimeLog 
                @async HTTP.serve(router |> x -> requestHandler(x, server_data) |> x -> AuthHandler(x, UUID(s.uuid)),
                                  "0.0.0.0", port, server = server)
                save(s)
                while !server_data.stop
                    sleep(1)
                end
                fetch(t)
                fetch(connections_task)
                close(server)
                return 0
            catch e
                log_error(e)
                rethrow(e)
            end
        end
    end
end
