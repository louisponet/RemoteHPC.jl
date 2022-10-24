
function path(req::HTTP.Request)
    p = req.target
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
    HTTP.register!(router, "GET", "/read/**", api_read)
    HTTP.register!(router, "GET", "/readdir/**", api_readdir)
    HTTP.register!(router, "GET", "/mtime/**", api_mtime)
    HTTP.register!(router, "GET", "/filesize/**", api_filesize)
    HTTP.register!(router, "GET", "/api/**", execute_function)
    HTTP.register!(router, "POST", "/write/**", api_write)
    HTTP.register!(router, "POST", "/rm/**", api_rm)
    return HTTP.register!(router, "POST", "/symlink/", api_symlink)
end

submit_job(req, channel) = put!(channel, path(req))

function get_job(job_dir::AbstractString, queue::Queue)
    info = get(queue.info.current_queue, job_dir, nothing)
    if info === nothing
        info = get(queue.info.full_queue, job_dir, nothing)
    end

    return (info,
            JSON3.read(read(joinpath(job_dir, ".remotehpc_info")),
                       Tuple{String,Environment,Vector{Calculation}})...)
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
    HTTP.register!(router, "GET", "/job/**", (req) -> get_job(path(req), queue))
    HTTP.register!(router, "GET", "/jobs/state",
                   (req) -> get_jobs(JSON3.read(req.body, JobState), queue))
    HTTP.register!(router, "GET", "/jobs/fuzzy",
                   (req) -> get_jobs(JSON3.read(req.body, String), queue))
    return HTTP.register!(router, "POST", "/abort/**",
                          (req) -> abort(req, queue, scheduler))
end

function load(req::HTTP.Request)
    p = path(req)
    if !isempty(HTTP.body(req))
        # This part basically exists for when more complicated things need to be done
        # when loading an entity (e.g. a Job).
        typ = Symbol(HTTP.header(req, "Type"))
        val = eval(:(JSON3.read($(req.body), $typ)))
        try
            return load(val)
        catch
            return map(x -> storage_name(x), replacements(val))
        end
    else
        cpath = config_path(p)
        if isempty(splitext(p)[end])
            # Here we return the possibilities
            return map(x -> splitext(x)[1], readdir(cpath))
        else
            return read(cpath, String)
        end
    end
end

function save(req::HTTP.Request)
    p = path(req)
    if HTTP.hasheader(req, "Type")
        # This part basically exists for when more complicated things need to be done
        # when storing an entity (e.g. a Job).
        typ = Symbol(HTTP.header(req, "Type"))
        eval(:(save(JSON3.read($(req.body), $typ))))
    else
        mkpath(splitdir(p)[1])
        write(p, req.body)
    end
end
function database_rm(req)
    p = config_path(path(req))
    ispath(p)
    return rm(p)
end

function name(req)
    typ = Symbol(HTTP.header(req, "Type"))
    val = eval(:(JSON3.read($(req.body), $typ)))
    return name(val)
end

function setup_database_api!(router)
    HTTP.register!(router, "GET", "/database/storage/**", load)
    HTTP.register!(router, "POST", "/database/storage/**", save)
    HTTP.register!(router, "PUT", "/database/storage/**", database_rm)
    return HTTP.register!(router, "GET", "/database/name", name)
end
