function execute_function(req::HTTP.Request)
    funcstr = Meta.parse(queryparams(req)["path"])
    func = eval(funcstr)
    args = []
    for (t, a) in JSON3.read(req.body, Vector)
        typ = Symbol(t)
        eval(:(arg = JSON3.read($a, $typ)))
        push!(args, arg)
    end
    return func(args...)
end

function get_info(req, s::ServerData)
    query = queryparams(req)
    out = []
    
    if !haskey(query, "info")
        error("No information requested.")
    else
        info = length(query["info"]) == 1 ? [query["info"]] : query["info"]
        for i in info
            if i == "version"
                push!(out, PACKAGE_VERSION)
            elseif i == "server"
                push!(out, s.server)
            end
        end
    end
    return out
end

function server_config!(req, s::ServerData)
    splt = splitpath(req.target)
    if splt[4] == "sleep_time"
        return s.sleep_time = parse(Float64, splt[5])
    end 
    field = Symbol(splt[4])
    server = s.server
    setfield!(server, field, parse(fieldtype(server, field), splt[5]))
    save(server)
    return server
end
function server_config(req, s::ServerData)
    server = s.server
    splt = splitpath(req.target)
    if length(splt) == 3
        return server
    else
        return getfield(server, Symbol(splt[4]))
    end
end

function setup_core_api!(s::ServerData)
    @put  "/server/kill" req -> (s.stop = true;terminate())
    @get  "/info/"       req -> get_info(req, s)
    @get  "/isalive/"    req -> true
    @get  "/isalive/*"   req -> (n = splitpath(req.target)[end]; haskey(s.connections, n) && s.connections[n])
    @get  "/api/**"      execute_function
    
    @get  "/ispath/"     req -> (p = queryparams(req)["path"]; ispath(p))
    @get  "/read/"       req -> (p = queryparams(req)["path"]; read(p))
    @post "/write/"      req -> (p = queryparams(req)["path"]; write(p, req.body))
    @post "/rm/"         req -> (p = queryparams(req)["path"]; rm(p; recursive = true))
    @get  "/readdir/"    req -> (p = queryparams(req)["path"]; readdir(p))
    @get  "/mtime/"      req -> (p = queryparams(req)["path"]; mtime(p))
    @get  "/filesize/"   req -> (p = queryparams(req)["path"]; filesize(p))
    @get  "/realpath/"   req -> (p = queryparams(req)["path"]; realpath(p))
    @post "/mkpath/"     req -> (p = queryparams(req)["path"]; mkpath(p))
    @post "/symlink/"    req -> symlink(JSON3.read(req.body, Vector{String})...)
    @post "/cp/"         req -> cp(JSON3.read(req.body, Tuple{String, String})...; force=true)
    
    @post "/server/config/*"  req -> server_config!(req, s)
    @get  "/server/config/**" req -> server_config(req, s)
    @get  "/server/config"    req -> local_server()
    @put  "/server/check_connections"   req -> check_connections!(s, get(queryparams(req), "verify_tunnels", false))
    @put  "/server/check_connections/*" req -> check_connections!(s, get(queryparams(req), "verify_tunnels", true); names=[splitpath(req.target)[end]])
end

function submit_job(req, queue::Queue, channel)
    p = queryparams(req)
    jdir = p["path"]
    lock(queue) do q
        if !haskey(q.full_queue, jdir)
            error("No Job is present at $jdir.")
        else
            q.full_queue[jdir].state = Submitted
        end
    end
    priority = haskey(p, "priority") ? parse(Int, p["priority"]) : DEFAULT_PRIORITY
    put!(channel, jdir => priority)
end 
        
function get_job(req::HTTP.Request, queue::Queue)
    p = queryparams(req)
    job_dir = p["path"]
    info = get(queue.info.current_queue, job_dir, nothing)
    if info === nothing
        info = get(queue.info.full_queue, job_dir, nothing)
    end
    info = info === nothing ? Job(-1, Unknown) : info
    tquery = HTTP.queryparams(URI(req.target))
    if isempty(tquery) || !haskey(tquery, "data")
        return [info,
                JSON3.read(read(joinpath(job_dir, ".remotehpc_info")),
                           Tuple{String,Environment,Vector{Calculation}})...]
    else
        dat = tquery["data"] isa Vector ? tquery["data"] : [tquery["data"]]
        out = []
        jinfo = any(x -> x in ("name", "environment", "calculations"), dat) ? JSON3.read(read(joinpath(job_dir, ".remotehpc_info")),
                           Tuple{String,Environment,Vector{Calculation}}) : nothing
        for d in dat
            if d == "id"
                push!(out, info.id)
            elseif d == "state"
                push!(out, info.state)
            elseif d == "name"
                if jinfo !== nothing
                    push!(out, jinfo[1])
                end
           elseif d == "environment"
                if jinfo !== nothing
                    push!(out, jinfo[2])
                end
            elseif d == "calculations"
                if jinfo !== nothing
                    push!(out, jinfo[3])
                end
            end
        end
        return out
    end
end

function get_jobs(state::JobState, queue::Queue)
    jobs = String[]
    for q in (queue.info.full_queue, queue.info.current_queue)
        for (d, j) in q
            if j.state == state
                push!(jobs, d)
            end
        end
    end
    return jobs
end

function get_jobs(dirfuzzy::AbstractString, queue::Queue)
    jobs = String[]
    for q in (queue.info.full_queue, queue.info.current_queue)
        for (d, j) in q
            if occursin(dirfuzzy, d)
                push!(jobs, d)
            end
        end
    end
    return jobs
end

function save_job(req::HTTP.Request, args...)
    return save_job(queryparams(req)["path"],
                    JSON3.read(req.body, Tuple{String,Environment,Vector{Calculation}}),
                    args...)
end

function save_job(dir::AbstractString, job_info::Tuple, queue::Queue, sched::Scheduler)
    # Needs to be done so the inputs `dir` also changes.
    mkpath(dir)
    open(joinpath(dir, "job.sh"), "w") do f
        return write(f, job_info, sched)
    end
    JSON3.write(joinpath(dir, ".remotehpc_info"), job_info)
    lock(queue) do q
        return q.full_queue[dir] = Job(-1, Saved)
    end
end

function abort(req::HTTP.Request, queue::Queue, sched::Scheduler)
    jdir = queryparams(req)["path"]
    j = get(queue.info.current_queue, jdir, nothing)
    if j === nothing
        if haskey(queue.info.submit_queue, jdir)
            lock(queue) do q
                delete!(q.submit_queue, jdir)
                q.full_queue[jdir].state = Cancelled
            end
            return 0
        else
            error("No Job is running or submitted at $jdir.")
        end
    else
        abort(sched, j.id)
        lock(queue) do q
            j = pop!(q.current_queue, jdir)
            j.state = Cancelled
            q.full_queue[jdir] = j
        end

        return j.id
    end
end

function priority!(req::HTTP.Request, queue::Queue)
    p = queryparams(req)
    jdir = p["path"]
    if haskey(queue.info.submit_queue, jdir) 
        priority = haskey(p, "priority") ? parse(Int, p["priority"]) : DEFAULT_PRIORITY
        lock(queue) do q
            q.submit_queue[jdir] = priority
        end
        return priority
    else
        error("Job at $jdir not in submission queue.")
    end
end

function setup_job_api!(s::ServerData)
    @post "/job/"         req -> save_job(req, s.queue, s.server.scheduler)
    @put  "/job/"         req -> submit_job(req, s.queue, s.submit_channel)
    @put  "/job/priority" req -> priority!(req, s.queue)
    @get  "/job/"         req -> get_job(req, s.queue)
    @get  "/jobs/state"   req -> get_jobs(JSON3.read(req.body, JobState), s.queue)
    @get  "/jobs/fuzzy"   req -> get_jobs(JSON3.read(req.body, String), s.queue)
    @post "/abort/"       req -> abort(req, s.queue, s.server.scheduler)
end

function load(req::HTTP.Request)
    p = config_path("storage", queryparams(req)["path"])
    if isdir(p)
        return map(x -> splitext(x)[1], readdir(p))
    else
        p *= ".json"
        if ispath(p)
            return read(p, String)
        end
    end
end

function save(req::HTTP.Request)
    p = config_path("storage", queryparams(req)["path"])
    mkpath(splitdir(p)[1])
    write(p * ".json", req.body)
end

function database_rm(req)
    p = config_path("storage", queryparams(req)["path"]) * ".json"
    ispath(p)
    return rm(p)
end

function setup_database_api!()
    @get  "/storage/" req -> load(req)
    @post "/storage/" req -> save(req)
    @put  "/storage/" req -> database_rm(req)
end
