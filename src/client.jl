"""
    start(s::Server)

Launches the daemon process on  the host [`Server`](@ref) `s`.
"""
function start(s::Server)
    @assert !isalive(s) "Server is already up and running."
    @info "Starting:\n$s"
    hostname = gethostname(s)
    if islocal(s)
        t = ispath(config_path("self_destruct"))
    else
        cmd = "cat ~/.julia/config/RemoteHPC/$hostname/self_destruct"
        t = server_command(s, cmd).exitcode == 0
    end
           
    @assert !t "Self destruction was previously triggered, signalling issues on the Server.\nPlease investigate and if safe, remove ~/.julia/config/RemoteHPC/self_destruct"

    
    # Here we clean up previous connections and commands
    if !islocal(s)
        if s.local_port != 0
            destroy_tunnel(s)
        end
       
        t = deepcopy(s)
        t.domain = "localhost"
        t.local_port = 0
        t.name = hostname
        tf = tempname()
        JSON3.write(tf,  t)
        push(tf, s, "~/.julia/config/RemoteHPC/$hostname/storage/servers/$hostname.json")
    end
        
    # Here we check what the modify time of the server-side localhost file is.
    # The server will rewrite the file with the correct port, which we use to see
    # whether the server started succesfully.
    function checktime()
        curtime = 0
        # try
            if islocal(s)
                return mtime(config_path("storage", "servers", "$(hostname).json"))
            else
                cmd = "stat -c %Z  ~/.julia/config/RemoteHPC/$hostname/storage/servers/$(hostname).json"
                return parse(Int, server_command(s.username, s.domain, cmd)[1])
            end
        # catch
        #     nothing
        # end
        return curtime
    end
    firstime = checktime()

    p = "~/.julia/config/RemoteHPC/$hostname/logs/errors.log"
    scrpt = "using RemoteHPC; RemoteHPC.run_server()"
    if s.domain != "localhost"
        julia_cmd = replace("""$(s.julia_exec) --startup-file=no -t 10 -e "using RemoteHPC; RemoteHPC.run_server()" &> $p""", "'" => "")
        run(Cmd(`ssh -f $(ssh_string(s)) $julia_cmd`, detach=true))
    else
        e = s.julia_exec
        julia_cmd = Cmd([string.(split(e))..., "--startup-file=no", "-t", "auto", "-e", scrpt, "&>", p, "&"])
        run(Cmd(julia_cmd, detach=true), wait=false)
    end
        
    #TODO: little hack here
    retries = 0
    prog = ProgressUnknown( "Waiting for server bootup:", spinner=true)
    while checktime() <= firstime && retries < 60
        ProgressMeter.next!(prog; spinner = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏", showvalues=[(:try, retries)])
        retries += 1
        sleep(1)
    end

    if retries == 60
        error("Something went wrong starting the server.")
    else

        tserver = load_config(s)
        s.port = tserver.port
        if s.local_port == 0
            @info "Daemon on Server $(s.name) started, listening on port $(s.port)."
        else
            construct_tunnel(s)
            @info "Daemon on Server $(s.name) started, listening on local port $(s.local_port)."
        end
        @info "Saving updated server info..."
        save(s)
    end
    return s
end

"""
    kill(s::Server)

Kills the daemon process on [`Server`](@ref) `s`.
"""
Base.kill(s::Server) = HTTP.put(s, "/kill_server")

function restart(s::Server)
    kill(s)
    while isalive(s)
        sleep(0.1)
    end
    return start(s)
end

"""
    isalive(s::Server)

Will try to fetch some data from `s`. If the server is not running this will fail and
the return is `false`.
"""
function isalive(s::Server)
    try
        return HTTP.get(s, "/isalive", connect_timeout=2, retries=2) !== nothing
    catch
        return false
    end
end

function save(s::Server, dir::AbstractString, n::AbstractString, e::Environment, calcs::Vector{Calculation})
    adir = abspath(s, dir)
    HTTP.post(s, "/job/" * adir, (n, e, calcs))
    return adir
end

function load(s::Server, dir::AbstractString)
    adir = abspath(s, dir)
    resp = HTTP.get(s, "/job/" * adir)
    info, name, environment, calculations = JSON3.read(resp.body, Tuple{Job, String, Environment, Vector{Calculation}}) 
    return (;info, name, environment, calculations)
end

function submit(s::Server, dir::AbstractString)
    adir = abspath(s, dir)
    HTTP.put(s, "/job/" * adir)
end
function submit(s::Server, dir::AbstractString, n::AbstractString, args...)
    adir = save(s, dir, n, args...)
    submit(s, adir)
    return adir
end

function abort(s::Server, dir::AbstractString)
    adir = abspath(s, dir)
    resp = HTTP.post(s, "/abort/" *adir)
    if resp.status == 200
        id = JSON3.read(resp.body, Int)
        @info "Aborted job with id $id."
    else
        return resp
    end
end

function state(s::Server, dir::AbstractString)
    return load(s, dir).info.state
end
