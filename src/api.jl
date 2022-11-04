function path(req::HTTP.Request)
    p = HTTP.URI(req.target).path
    id = findnext(isequal('/'), p, 2)
    if length(p) < id + 1
        return ""
    else
        return p[id+1:end]
    end
end

get_server_config(req)          = local_server()
api_ispath(req::HTTP.Request)   = ispath(path(req))
api_read(req::HTTP.Request)     = read(path(req))
api_write(req::HTTP.Request)    = write(path(req), req.body)
api_rm(req::HTTP.Request)       = rm(path(req); recursive = true)
api_symlink(req::HTTP.Request)  = symlink(JSON3.read(req.body, Vector{String})...)
api_readdir(req::HTTP.Request)  = readdir(path(req))
api_mtime(req::HTTP.Request)    = mtime(path(req))
api_filesize(req::HTTP.Request) = filesize(path(req))
api_realpath(req::HTTP.Request) = realpath(path(req))
api_mkpath(req::HTTP.Request)   = mkpath(path(req))
api_cp(req::HTTP.Request)       = cp(JSON3.read(req.body, Tuple{String, String})...; force=true)

function execute_function(req::HTTP.Router)
    funcstr = Meta.parse(path(req))
    func = eval(funcstr)
    args = []
    for (t, a) in JSON3.read(req.body, Vector)
        typ = Symbol(t)
        eval(:(arg = JSON3.read($a, $typ)))
        push!(args, arg)
    end
    return func(args...)
end

function setup_core_api!(router::HTTP.Router)
    HTTP.register!(router, "GET", "/server_config", get_server_config)
    HTTP.register!(router, "GET", "/isalive", (res) -> true)
    HTTP.register!(router, "GET", "/ispath/**", api_ispath)
    HTTP.register!(router, "GET", "/realpath/**", api_realpath)
    HTTP.register!(router, "GET", "/read/**", api_read)
    HTTP.register!(router, "GET", "/readdir/**", api_readdir)
    HTTP.register!(router, "GET", "/mtime/**", api_mtime)
    HTTP.register!(router, "GET", "/filesize/**", api_filesize)
    HTTP.register!(router, "GET", "/api/**", execute_function)
    HTTP.register!(router, "POST", "/write/**", api_write)
    HTTP.register!(router, "POST", "/rm/**", api_rm)
    HTTP.register!(router, "POST", "/symlink/", api_symlink)
    HTTP.register!(router, "POST", "/mkpath/**", api_mkpath)
    HTTP.register!(router, "POST", "/cp/", api_cp)
end

submit_job(req, channel) = put!(channel, path(req))

function get_job(req::HTTP.Request, queue::Queue)
    job_dir = path(req)
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
    return save_job(path(req),
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
    jdir = path(req)
    j = get(queue.info.current_queue, jdir, nothing)
    if j === nothing
        error("No Job is running at $jdir.")
    end
    abort(sched, j.id)
    lock(queue) do q
        j = pop!(q.current_queue, jdir)
        j.state = Cancelled
        return q.full_queue[jdir] = j
    end

    return j.id
end

function setup_job_api!(router::HTTP.Router, submit_channel, queue::Queue,
                        scheduler::Scheduler)
    HTTP.register!(router, "POST", "/job/**", (req) -> save_job(req, queue, scheduler))
    HTTP.register!(router, "PUT", "/job/**", (req) -> submit_job(req, submit_channel))
    HTTP.register!(router, "GET", "/job/**", (req) -> get_job(req, queue))
    HTTP.register!(router, "GET", "/jobs/state",
                   (req) -> get_jobs(JSON3.read(req.body, JobState), queue))
    HTTP.register!(router, "GET", "/jobs/fuzzy",
                   (req) -> get_jobs(JSON3.read(req.body, String), queue))
    return HTTP.register!(router, "POST", "/abort/**",
                          (req) -> abort(req, queue, scheduler))
end

function load(req::HTTP.Request)
    p = config_path(strip(req.target, '/'))
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
    p = config_path(strip(req.target, '/'))
    mkpath(splitdir(p)[1])
    write(p * ".json", req.body)
end

function database_rm(req)
    p = config_path(strip(req.target, '/')) * ".json"
    ispath(p)
    return rm(p)
end

function setup_database_api!(router)
    HTTP.register!(router, "GET", "/storage/**", load)
    HTTP.register!(router, "POST", "/storage/**", save)
    HTTP.register!(router, "PUT", "/storage/**", database_rm)
end
