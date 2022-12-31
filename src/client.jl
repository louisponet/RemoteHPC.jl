"""
    start(s::Server)

Launches the daemon process on  the host [`Server`](@ref) `s`.
"""
function start(s::Server; verbose=0)
    if !islocal(s) && !isalive(LOCAL_SERVER[])
        @warn "Local server not running. Starting that first."
        start(LOCAL_SERVER[])
        if !isalive(LOCAL_SERVER[])
            error("Couldn't start local server.")
        end
    end
    alive = isalive(s)
    @assert !alive "Server is already up and running."
    @debug "Starting:\n$s"
    hostname = gethostname(s)
    conf_path = config_path(s)
    t = server_command(s, "ls $(conf_path)")
    if t.exitcode != 0
        error("RemoteHPC not installed on server. Install it using `RemoteHPC.install_RemoteHPC(Server(\"$(s.name)\"))`")
    end
    
    if islocal(s)
        t = ispath(config_path("self_destruct"))
    else
        cmd = "cat $(conf_path)/$hostname/self_destruct"
        t = server_command(s, cmd).exitcode == 0
    end

    @assert !t "Self destruction was previously triggered, signalling issues on the Server.\nPlease investigate and if safe, remove $(conf_path)/self_destruct"

    if !islocal(s)
        t = deepcopy(s)
        t.domain = "localhost"
        t.name = hostname
        tf = tempname()
        JSON3.write(tf, t)
        push(tf, s, "$(conf_path)/$hostname/storage/servers/$hostname.json")
    end

    # Here we check what the modify time of the server-side localhost file is.
    # The server will rewrite the file with the correct port, which we use to see
    # whether the server started succesfully.
    function checktime()
        curtime = 0
        if islocal(s)
            return mtime(config_path("storage", "servers", "$(hostname).json"))
        else
            cmd = "stat -c %Z  $(conf_path)/$hostname/storage/servers/$(hostname).json"
            return parse(Int, server_command(s.username, s.domain, cmd)[1])
        end
        return curtime
    end
    firstime = checktime()

    p = "$(conf_path)/$hostname/logs/errors.log"
    scrpt = "using RemoteHPC; RemoteHPC.julia_main(verbose=$(verbose))"
    if s.domain != "localhost"
        julia_cmd = replace("""$(s.julia_exec) --project=$(conf_path) --startup-file=no -t 10 -e "using RemoteHPC; RemoteHPC.julia_main(verbose=$(verbose))" &> $p""",
                            "'" => "")
        if Sys.which("ssh") === nothing
            OpenSSH_jll.ssh() do ssh_exec
                run(Cmd(`$ssh_exec -f $(ssh_string(s)) $julia_cmd`; detach = true))
            end
        else
            run(Cmd(`ssh -f $(ssh_string(s)) $julia_cmd`; detach = true))
        end
    else
        e = s.julia_exec * " --project=$(conf_path)"
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
    finish!(prog)

    if retries == 60
        error("Something went wrong starting the server.")
    else
        if islocal(s)
            s.port = load_config(s).port
        end
        
        @debug "Daemon on Server $(s.name) started, listening on local port $(s.port)."
        @debug "Saving updated server info..."
        save(s)
    end
    HTTP.put(LOCAL_SERVER[], URI(path="/server/check_connections"))
    while isalive(LOCAL_SERVER[]) && !isalive(s)
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
        @debug "Server is alive, killing"
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
    if islocal(s)
        try
            return HTTP.get(s, URI(path="/isalive/"); connect_timeout = 2, retries = 2) !== nothing
        catch
            return false
        end
    else
        if !isalive(LOCAL_SERVER[])
            error("Local server not running. Use `start(local_server())` first.")
        end
        return JSON3.read(HTTP.get(LOCAL_SERVER[], URI(path="/isalive/$(s.name)"); connect_timeout = 2, retries = 2).body, Bool)
    end
end

function save(s::Server, dir::AbstractString, e::Environment, calcs::Vector{Calculation};
              name = "RemoteHPC_job")
    adir = abspath(s, dir)
    HTTP.post(s, URI(path="/job/", query = Dict("path" => adir)), (name, e, calcs))
    return adir
end

function load(s::Server, dir::AbstractString)
    adir = abspath(s, dir)
    if !ispath(s, joinpath(adir, ".remotehpc_info"))
        resp = HTTP.get(s, URI(path="/jobs/fuzzy/"), dir)
        return JSON3.read(resp.body, Vector{String})
    else
        resp = HTTP.get(s, URI(path="/job/", query=Dict("path" => adir)))
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
    return HTTP.put(s, URI(path="/job/", query = Dict("path" => adir)))
end
function submit(s::Server, dir::AbstractString, e::Environment, calcs::Vector{Calculation};
                kwargs...)
    adir = save(s, dir, e, calcs; kwargs...)
    submit(s, adir)
    return adir
end

function abort(s::Server, dir::AbstractString)
    adir = abspath(s, dir)
    resp = HTTP.post(s, URI(path="/abort/", query=Dict("path" => adir)))
    if resp.status == 200
        id = JSON3.read(resp.body, Int)
        @debug "Aborted job with id $id."
    else
        return resp
    end
end

function state(s::Server, dir::AbstractString)
    adir = abspath(s, dir)
    url = URI(path = "/job/", query = Dict("path" => adir, "data" => ["state"]))
    resp = HTTP.get(s, url)
    return JSON3.read(resp.body, Tuple{JobState})[1]
end

ask_name(::Type{S}) where {S} = ask_input(String, "Please specify a name for the new $S")

function configure()
    @debug "Configuring (start with Servers)..."
    done = false
    while !done
        storables = subtypes(Storable)
        type = request("Which kind would you like to configure?", RadioMenu(string.(storables)))
        type == -1 && return
        storable_T = storables[type]
        @debug "Configuring a $storable_T. Please read carefully the documentation first:"
        display(Docs.doc(storable_T)) 
        name = ask_name(storable_T)
        if storable_T == Server
            server = local_server()
        else
            servers = ["local"; load(local_server(), Server(""))]
            server_id = request("Where would you like to save the $storable_T?", RadioMenu(servers))
            server_id == -1 && return
            if server_id == 1
                server = local_server()
            else
                server = Server(servers[server_id])
            end
        end
        if !isalive(server)
            error("Server(\"$(server.name)\") is not alive, start it first")
        end
        storable = storable_T(name=name)

        if isalive(server) && exists(server, storable)
            id = request("A $storable_T with name $name already exists on $(server.name). Overwrite?", RadioMenu(["no", "yes"]))
            id < 2 && return
            storable = load(server, storable)
        end

        if storable_T == Server
            storable = Server(name, true)
        else
            storable = configure!(storable, server)
        end
        yn_id = request("Proceed saving $storable_T with name $name to Server $(server.name)", RadioMenu(["yes", "no"]))
        if yn_id == 1
            save(server, storable)
        end

        yn_id = request("Configure more Storables?", RadioMenu(["yes", "no"]))
        done = yn_id == 2
    end
end

function ask_input(::Type{T}, message, default = nothing) where {T}
    message *= " [$T]"
    if default === nothing
        t = ""
        print(message * ": ")
        while isempty(t)
            t = readline()
        end
    else
        if !(T == String && isempty(default))
            message *= " (default: $default)"
        end
        print(message * ": ")
        t = readline()
        if isempty(t)
            return default
        end
    end
    if T in (Int, Float64, Float32) 
        return parse(T, t)
    elseif T == String
        return String(strip(t))
    else
        out = T(eval(Meta.parse(t)))
        if out isa T
            return out
        else
            error("Can't parse $t as $T")
        end
    end
end

function configure!(storable::T, s::Server) where {T<:Storable}
    tf = tempname()
    open(tf, "w") do f
        write(f, "Storable configuration (read documentation below):\n\n")
        for field in configurable_fieldnames(T)
            value = getfield(storable, field)
            ft = typeof(value)
            write(f, "$field::$ft = $(repr(value))\n")
        end
        write(f, "########## DOCUMENTATION #########\n")
        write(f, string(Docs.doc(T)))
        write(f, "\n")
        write(f, "########## DOCUMENTATION END #####\n\n\n")
    end
    InteractiveUtils.edit(tf)
    tstr = filter(!isempty, readlines(tf))
    i = findfirst(x->occursin("Storable configuration",x), tstr)
    for (ii, f) in enumerate(configurable_fieldnames(T))
        field = getfield(storable, f)
        ft = typeof(field)
        line = tstr[i+ii]
        sline = split(line, "=")
        # try
            if length(sline) > 2
                v = Main.eval(Meta.parse(join(sline[2:end], "=")))
            else
                v = Main.eval(Meta.parse(sline[end]))
            end
                
            setfield!(storable, f, v)
        # catch e
        #     @warn "Failed parsing $(split(tstr[i+ii], "=")[end]) as $ft. Try again"
        #     @error stacktrace(catch_backtrace())
        #     print("Press any key to continue...\n")
        #     readline()
        #     configure!(storable, s)
        # end
    end
        
    rm(tf)
    return storable
end
