"""
    start(s::Server)

Launches the daemon process on  the host [`Server`](@ref) `s`.
"""
function start(s::Server)
    alive = isalive(s)
    @assert !alive "Server is already up and running."
    @info "Starting:\n$s"
    hostname = gethostname(s)
    if islocal(s)
        t = ispath(config_path("self_destruct"))
    else
        cmd = "cat ~/.julia/config/RemoteHPC/$hostname/self_destruct"
        t = server_command(s, cmd).exitcode == 0
    end

    @assert !t "Self destruction was previously triggered, signalling issues on the Server.\nPlease investigate and if safe, remove ~/.julia/config/RemoteHPC/self_destruct"

    if !islocal(s)
        t = deepcopy(s)
        t.domain = "localhost"
        t.name = hostname
        tf = tempname()
        JSON3.write(tf, t)
        push(tf, s, "~/.julia/config/RemoteHPC/$hostname/storage/servers/$hostname.json")
    end

    # Here we check what the modify time of the server-side localhost file is.
    # The server will rewrite the file with the correct port, which we use to see
    # whether the server started succesfully.
    function checktime()
        curtime = 0
        if islocal(s)
            return mtime(config_path("storage", "servers", "$(hostname).json"))
        else
            cmd = "stat -c %Z  ~/.julia/config/RemoteHPC/$hostname/storage/servers/$(hostname).json"
            return parse(Int, server_command(s.username, s.domain, cmd)[1])
        end
        return curtime
    end
    firstime = checktime()

    p = "~/.julia/config/RemoteHPC/$hostname/logs/errors.log"
    scrpt = "using RemoteHPC; RemoteHPC.julia_main()"
    if s.domain != "localhost"
        julia_cmd = replace("""$(s.julia_exec) --project=~/.julia/config/RemoteHPC/ --startup-file=no -t 10 -e "using RemoteHPC; RemoteHPC.julia_main()" &> $p""",
                            "'" => "")
        OpenSSH_jll.ssh() do ssh_exec
            run(Cmd(`$ssh_exec -f $(ssh_string(s)) $julia_cmd`; detach = true))
        end
    else
        e = s.julia_exec * " --project=~/.julia/config/RemoteHPC/"
        julia_cmd = Cmd([string.(split(e))..., "--startup-file=no", "-t", "auto", "-e",
                         scrpt, "&>", p, "&"])
        run(Cmd(julia_cmd; detach = true); wait = false)
    end

    #TODO: little hack here
    retries = 0
    prog = ProgressUnknown("Waiting for server bootup:"; spinner = true)
    while checktime() <= firstime && retries < 60
        ProgressMeter.next!(prog; spinner = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏", showvalues = [(:try, retries)])
        retries += 1
        sleep(1)
    end

    if retries == 60
        error("Something went wrong starting the server.")
    else
        if !islocal(s)
            remote_server = load_config(s.username, s.domain)
            s.port = construct_tunnel(s, remote_server.port)
        else
            s.port = load_config(s).port
        end
        @info "Daemon on Server $(s.name) started, listening on local port $(s.port)."
        @info "Saving updated server info..."
        save(s)
    end
    while !isalive(s)
        sleep(0.1)
    end
    return s
end

"""
    kill(s::Server)

Kills the daemon process on [`Server`](@ref) `s`.
"""
function Base.kill(s::Server)
    HTTP.put(s, URI(path="/server/kill"))
    destroy_tunnel(s)
    while isalive(s)
        sleep(0.1)
    end
end

function restart(s::Server)
    kill(s)
    return start(s)
end

function update_config(s::Server)
    alive = isalive(s)
    if alive
        @info "Server is alive, killing"
        kill(s)
    end
    save(s)
    return start(s)
end

"""
    isalive(s::Server)

Will try to fetch some data from `s`. If the server is not running this will fail and
the return is `false`.
"""
function isalive(s::Server)
    try
        return HTTP.get(s, URI(path="/isalive"); connect_timeout = 2, retries = 2) !== nothing
    catch
        if !islocal(s)
            t = find_tunnel(s)
            if t === nothing
                # Tunnel was dead -> create one and try again
                remote_server = load_config(s.username, s.domain)
                remote_server === nothing && return false
                s.port = construct_tunnel(s, remote_server.port)
                try
                    return HTTP.get(s, URI(path="/isalive"); connect_timeout = 2, retries = 2) !== nothing
                catch
                    # Still no connection -> destroy tunnel because server dead
                    destroy_tunnel(s)
                    return false
                end
            else
                # Tunnel existed but no connection -> server dead
                destroy_tunnel(s)
                return false
            end
        else
            return false
        end
    end
end

function save(s::Server, dir::AbstractString, e::Environment, calcs::Vector{Calculation};
              name = "RemoteHPC_job")
    adir = abspath(s, dir)
    HTTP.post(s, URI(path="/job/" * adir), (name, e, calcs))
    return adir
end

function load(s::Server, dir::AbstractString)
    adir = abspath(s, dir)
    if !ispath(s, joinpath(adir, ".remotehpc_info"))
        resp = HTTP.get(s, URI(path="/jobs/fuzzy/"), dir)
        return JSON3.read(resp.body, Vector{String})
    else
        resp = HTTP.get(s, URI(path="/job/" * adir))
        info, name, environment, calculations = JSON3.read(resp.body,
                                                           Tuple{Job,String,Environment,
                                                                 Vector{Calculation}})
        return (; info, name, environment, calculations)
    end
end
function load(s::Server, state::JobState)
    resp = HTTP.get(s, URI(path="/jobs/state/"), state)
    return JSON3.read(resp.body, Vector{String})
end

function submit(s::Server, dir::AbstractString)
    adir = abspath(s, dir)
    return HTTP.put(s, URI(path="/job/" * adir))
end
function submit(s::Server, dir::AbstractString, e::Environment, calcs::Vector{Calculation};
                kwargs...)
    adir = save(s, dir, e, calcs; kwargs...)
    submit(s, adir)
    return adir
end

function abort(s::Server, dir::AbstractString)
    adir = abspath(s, dir)
    resp = HTTP.post(s, URI(path="/abort/" * adir))
    if resp.status == 200
        id = JSON3.read(resp.body, Int)
        @info "Aborted job with id $id."
    else
        return resp
    end
end

function state(s::Server, dir::AbstractString)
    adir = abspath(s, dir)
    url = URI(path = "/job/" * adir, query = Dict("data" => ["state"]))
    resp = HTTP.get(s, url)
    return JSON3.read(resp.body, Tuple{JobState})[1]
end
