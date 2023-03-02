using REPL.TerminalMenus
using OpenSSH_jll
const SERVER_DIR = config_path("storage/servers")

"""
    Server(name                ::String,
           username            ::String,
           domain              ::String,
           scheduler           ::Scheduler,
           julia_exec          ::String,
           jobdir              ::String,
           max_concurrent_jobs ::Int)
    Server(name::String)

A [`Server`](@ref) represents a daemon running either locally or on some remote cluster.
It facilitates all remote operations that are required to save, submit, monitor and retrieve HPC jobs.

As with any [`Storable`](@ref), `name` is used simply as a label.

`username` and `domain` should be those that allow for `ssh` connections between your local machine and the remote host.
Make sure that passwords are not required to execute `ssh` commands, i.e. by having copied your `ssh` keys using `ssh-copy-id`. 

`julia_exec` should be the path on the remote host where to find the `julia` executable.
`scheduler` will be automatically deduced but can be overridden if needed.
"""
@kwdef mutable struct Server <: Storable
    name::String = ""
    username::String = ""
    domain::String = ""
    scheduler::Scheduler = Bash()
    julia_exec::String = "julia"
    jobdir::String = ""
    port::Int = 8080
    max_concurrent_jobs::Int = 100
    uuid::String = ""
end

storage_directory(::Server) = "servers"

function configure_scheduler(s::Server; interactive = true)
    scheduler = nothing
    if haskey(ENV, "REMOTEHPC_SCHEDULER")
        sched = ENV["REMOTEHPC_SCHEDULER"]
        if occursin("hq", lowercase(sched))
            cmd = get(ENV, "REMOTEHPC_SCHEDULER_CMD", "hq")
            return HQ(; server_command = cmd)
        elseif lowercase(sched) == "slurm"
            return Slurm()
        else
            error("Scheduler $sched not recognized please set a different REMOTEHPC_SCHEDULER environment var.")
        end
    end

    for t in (HQ(), Slurm())
        scmd = submit_cmd(t)
        if server_command(s, "which $scmd").exitcode == 0
            scheduler = t
            break
        end
    end
    if scheduler !== nothing
        return scheduler
    end
    if interactive && scheduler === nothing
        choice = request("Couldn't identify the scheduler select one: ",
                         RadioMenu(["SLURM", "HQ", "BASH"]))

        if choice == 1
            scheduler = Slurm()
        elseif choice == 2
            scheduler = HQ(; server_command = ask_input(String, "HQ command", "hq"))
        elseif choice == 3
            scheduler = Bash()
        else
            return
        end
        return scheduler
    else
        return Bash()
    end
end

function configure!(s::Server; interactive = true)
    if s.domain == "localhost"
        s.julia_exec = joinpath(Sys.BINDIR, "julia")
    else
        if interactive
            username = ask_input(String, "Username")
            domain = ask_input(String, "Domain")
            if server_command(username, domain, "ls").exitcode != 0
                error("$username@$domain not reachable")
            end

            s = Server(name=s.name, username=username, domain=domain)
            @debug "Trying to pull existing configuration from $username@$domain..."
            server = load_config(username, domain, config_path(s))
            if server !== nothing
                
                server.name = s.name
                server.domain = s.domain

                change_config = request("Found remote server configuration:\n$server\nIs this correct?",
                                        RadioMenu(["yes", "no"]))
                change_config == -1 && return
                if change_config == 1
                    save(server)
                    return server
                else
                    s = server
                end
            else
                @debug "Couldn't pull server configuration, creating new..."
                server = Server(; name = s.name, domain = domain, username = username)
            end
            
            julia = ask_input(String, "Julia executable path", s.julia_exec)
            if server_command(s.username, s.domain, "which $julia").exitcode != 0
                yn_id = request("$julia, no such file or directory. Install julia?", RadioMenu(["yes", "no"]))
                yn_id == -1 && return 
                if yn_id == 1
                    s.julia_exec = install_julia(s)
                    install_RemoteHPC(s)
                else
                    @debug """
                    You will need to install julia, e.g. by using `RemoteHPC.install_julia` or manually on the cluster.
                    Afterwards don't forget to update server.julia_exec to the correct one before starting the server.
                    """
                end
            else
                s.julia_exec = julia
            end
        else
            s.julia_exec = "julia"
        end
    end

    # Try auto configuring the scheduler
    scheduler = configure_scheduler(s; interactive = interactive)
    if scheduler === nothing
        return
    end
    s.scheduler = scheduler
    hdir = server_command(s, "pwd").stdout[1:end-1]
    if interactive
        dir = ask_input(String, "Default Jobs directory", hdir)
        if dir != hdir
            while server_command(s, "ls $dir").exitcode != 0
                # @warn "$dir, no such file or directory."
                local_choice = request("No such directory, creating one?",
                                       RadioMenu(["yes", "no"]))
                if local_choice == 1
                    result = server_command(s, "mkdir -p $dir")
                    if result.exitcode != 0
                        @warn "Couldn't create $dir, try a different one."
                    end
                else
                    dir = ask_input(String, "Default jobs directory")
                end
            end
        end

        s.jobdir = dir
        s.max_concurrent_jobs = ask_input(Int, "Max Concurrent Jobs", s.max_concurrent_jobs)
    else
        s.jobdir = hdir
    end
    conf_path = config_path(s)
    t = server_command(s, "ls $(conf_path)")
    if t.exitcode != 0
        install_RemoteHPC(s)
    end
    s.uuid = string(uuid4())
    return s
end

"""
    configure_local()

Runs through interactive configuration of the local [`Server`](@ref).
"""
function configure_local(; interactive = true)
    host = gethostname()
    @assert !exists(Server(; name = host)) "Local server already configured."
    user = get(ENV, "USER", "nouser")
    s = Server(; name = host, username = user, domain = "localhost")
    configure!(s; interactive = interactive)

    @debug "saving server configuration...", s
    save(s)
    if interactive
        start_server = request("Start server?", RadioMenu(["yes", "no"]))
        start_server == -1 && return
        if start_server == 1
            start(s)
        end
    end
    return s
end

function Server(s::AbstractString; overwrite=false)
    t = Server(; name = s)
    return isempty(s) ? t : load(t)
end

islocal(s::Server) = s.domain == "localhost"

function local_server()
    s = Server(name=gethostname())
    if !exists(s)
        error("Local Server wasn't configured. Try running `using Pkg; Pkg.build(\"RemoteHPC\")`")
    end
    return load(s)
end

function install_julia(s::Server)
    julia_tar = "julia-1.8.5-linux-x86_64.tar.gz"
    p = ProgressUnknown("Installing julia on Server $(s.name) ($(s.username)@$(s.domain))...", spinner=true)
    t = tempname()
    mkdir(t)
    next!(p, showvalues = [("step [1/3]", "downloading")], keep=true)
    download("https://julialang-s3.julialang.org/bin/linux/x64/1.8/julia-1.8.5-linux-x86_64.tar.gz",
             joinpath(t, "julia.tar.gz"))
    next!(p, showvalues = [("step [2/3]", "pushing")], keep=true)
    push(joinpath(t, "julia.tar.gz"), s, julia_tar)
    rm(t; recursive = true)
    next!(p, showvalues = [("step [3/3]", "unpacking")], keep=true)
    res = server_command(s, "tar -xf $julia_tar")
    server_command(s, "rm $julia_tar")
    finish!(p)
    @assert res.exitcode == 0 "Issue unpacking julia executable on cluster, please install julia manually"
    @debug "julia installed on Server $(s.name) in ~/julia-1.8.5/bin"
    return "~/julia-1.8.5/bin/julia"
end

function install_RemoteHPC(s::Server, julia_exec = s.julia_exec)
    # We install the latest version of julia in the homedir
    res = server_command(s, "which $julia_exec")
    if res.exitcode != 0
        julia_exec = install_julia(s) 
    else
        julia_exec = res.stdout[1:end-1]
    end
    @info "Installing RemoteHPC"
    s.julia_exec = julia_exec
    res = julia_cmd(s, "using Pkg; Pkg.activate(joinpath(Pkg.depots()[1], \"config/RemoteHPC\")); Pkg.add(\"RemoteHPC\");Pkg.build(\"RemoteHPC\")")
    @assert res.exitcode == 0 "Something went wrong installing RemoteHPC on server, please install manually"

    @info "RemoteHPC installed on remote cluster, try starting the server with `start(server)`."
    return
end

function update_RemoteHPC(s::Server)
    p = ProgressUnknown("Updating RemoteHPC on Server $(s.name) ($(s.username)@$(s.domain))...", spinner=true, dt=0.0)
    curvals = [("step [1/3]", "Checking server status")]
    finished = false
    ptsk = Threads.@spawn begin
        while !finished
            next!(p, showvalues = curvals, spinner="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
            sleep(0.1)
        end
    end
    v = nothing
    try
        v = version(s)
        curvals = [("step [1/3]", "Current version $v")]
    catch
        curvals = [("step [1/3]", "Current version could not be determined")]
    end
        
    alive = isalive(s)
    if alive
        curvals = [("step [1/3]", "Server was alive, killing")]
        kill(s)
    end
    curvals = [("step [2/3]", "Updating RemoteHPC")]
    if islocal(s)
        curproj = Pkg.project().path
        Pkg.activate(joinpath(depot_path(s), "config/RemoteHPC"))
        Pkg.update()
        Pkg.activate(curproj)
    else
        curvals = [("step [2/3]", "Executing remote update command")]
        res = julia_cmd(s, "using Pkg; Pkg.activate(joinpath(Pkg.depots()[1], \"config/RemoteHPC\"));  Pkg.update(\"RemoteHPC\")")
        if res.exitcode != 0
            finished = true
            fetch(ptsk)
            finish!(p, spinner='✗')
            error("Error while updating Server $(s.name):\nstdout: $(res.stdout) stderr: $(res.stderr) exitcode: $(res.exitcode)")
        end
    end
    curvals = [("step [3/3]", "Restarting Server if needed")]
    if alive
        @debug "Restarting server."
        start(s)
    end
    finished = true
    fetch(ptsk)
    finish!(p)
    if v !== nothing
        newver = version(s)
        if v == newver
            @warn "Version did not update, is RemoteHPC installed from a fixed path on the Server?"
        else
            @info "Version $v -> $newver"
        end
    else
        @info "New version $(version(s))"
    end 
end

Base.joinpath(s::Server, p...) = joinpath(s.jobdir, p...)
function Base.ispath(s::Server, p...)
    return islocal(s) ? ispath(p...) :
           JSON3.read(HTTP.get(s, URI(path="/ispath/", query=Dict("path"=> joinpath(p...)))).body, Bool)
end

function Base.symlink(s::Server, p, p2)
    if islocal(s)
        symlink(p, p2)
    else
        HTTP.post(s, URI(path="/symlink/"), [p, p2])
        return nothing
    end
end

function Base.rm(s::Server, p::String)
    if islocal(s)
        isdir(p) ? rm(p; recursive = true) : rm(p)
    else
        HTTP.post(s, URI(path="/rm/", query=Dict("path" => p)))
        return nothing
    end
end
function Base.read(s::Server, path::String, type = nothing)
    if islocal(s)
        return type === nothing ? read(path) : read(path, type)
    else
        resp = HTTP.get(s, URI(path="/read/", query = Dict("path" =>path)))
        t = JSON3.read(resp.body, Vector{UInt8})
        return type === nothing ? t : type(t)
    end
end
function Base.write(s::Server, path::String, v)
    if islocal(s)
        write(path, v)
    else
        resp = HTTP.post(s, URI(path="/write/", query = Dict("path" => path)), Vector{UInt8}(v))
        return JSON3.read(resp.body, Int)
    end
end
function Base.mkpath(s::Server, dir)
    HTTP.post(s, URI(path="/mkpath/", query=Dict("path" => dir)))
    return dir
end
function Base.cp(s::Server, src, dst)
    HTTP.post(s, URI(path="/cp/"), (src, dst))
    return dst
end

parse_config(config) = JSON3.read(config, Server)
read_config(config_file) = parse_config(read(config_file, String))

config_path(s::Server, p...) = joinpath(depot_path(s), "config", "RemoteHPC", p...)

function load_config(username, domain, conf_path)
    hostname = gethostname(username, domain)
    if domain == "localhost"
        return parse_config(read(config_path("storage", "servers", "$hostname.json"),
                                 String))
    else
        t = server_command(username, domain,
                           "cat $(conf_path)/$hostname/storage/servers/$hostname.json")
        if t.exitcode != 0
            return nothing
        else
            return parse_config(t.stdout)
        end
    end
end
function load_config(s::Server)
    if isalive(s)
        return JSON3.read(HTTP.get(s, URI(path="/server/config/")).body, Server)
    else
        return load_config(s.username, s.domain, config_path(s))
    end
end

function Base.gethostname(username::AbstractString, domain::AbstractString)
    return split(server_command(username, domain, "hostname").stdout)[1]
end
Base.gethostname(s::Server) = gethostname(s.username, s.domain)

function depot_path(s::Server)
    if islocal(s)
        occursin("cache", Pkg.depots()[1]) ? Pkg.depots()[2] : Pkg.depots()[1]
    else
        t = julia_cmd(s, "print(realpath(Base.DEPOT_PATH[1]))")
        if t.exitcode != 0
            error("Server $(s.name) can't be reached:\n$(t.stderr)")
        end
        if occursin("cache", t.stdout)
            return julia_cmd(s, "print(realpath(Base.DEPOT_PATH[2]))").stdout
        else
            return t.stdout
        end
    end
end

function julia_cmd(s::Server, cmd::String)
    return server_command(s, "$(s.julia_exec) --startup-file=no -e ' $cmd '")
end

ssh_string(s::Server) = s.username * "@" * s.domain
function http_uri(s::Server, uri::URI = URI())
    return URI(uri, scheme="http", port=s.port, host = "localhost")
end
function http_uri(s::Server, uri::AbstractString)
    return URI(URI(uri), scheme="http", port=s.port, host = "localhost")
end

function Base.rm(s::Server)
    return ispath(joinpath(SERVER_DIR, s.name * ".json")) &&
           rm(joinpath(SERVER_DIR, s.name * ".json"))
end

function find_tunnel(s)
    if haskey(ENV, "USER")
        lines = readlines(`ps -o pid,command -u $(ENV["USER"])`)
    else
        lines = readlines(`ps -eo pid,command`)
    end
    t = getfirst(x -> occursin("-N -L", x) && occursin(ssh_string(s), x),
                        lines)
    if t !== nothing
        return parse(Int, split(t)[1])
    end
end

function destroy_tunnel(s)
    t = find_tunnel(s)
    if t !== nothing
        try
            run(`kill $t`)
        catch
            nothing
        end
    end
end

function construct_tunnel(s, remote_port)
    if Sys.which("ssh") === nothing
        OpenSSH_jll.ssh() do ssh_exec
            port, serv = listenany(Sockets.localhost, 0)
            close(serv)
            run(Cmd(`$ssh_exec -o ExitOnForwardFailure=yes -o ServerAliveInterval=60 -N -L $port:localhost:$remote_port $(ssh_string(s))`); wait=false)
            return port
        end
    else
        port, serv = listenany(Sockets.localhost, 0)
        close(serv)
        cmd = Cmd(`ssh -o ExitOnForwardFailure=yes -o ServerAliveInterval=60 -N -L $port:localhost:$remote_port $(ssh_string(s))`)
        run(cmd; wait=false)
        return port
    end 
end

"""
    pull(server::Server, remote::String, loc::String)

Pulls `remote` from the server to `loc`.
"""
function pull(server::Server, remote::String, loc::String)
    path = isdir(loc) ? joinpath(loc, splitpath(remote)[end]) : loc
    if islocal(server)
        cp(remote, path; force = true)
    else
        out = Pipe()
        err = Pipe()
        # OpenSSH_jll.scp() do scp_exec
            run(pipeline(`scp -r $(ssh_string(server) * ":" * remote) $path`; stdout = out,
                         stderr = err))
        # end
        close(out.in)
        close(err.in)
        stderr = read(err, String)
        if !isempty(stderr)
            error("$stderr")
        end
    end
    return path
end

"""
    push(local_file::String, server::Server, server_file::String)

Pushes the `local_file` to the `server_file` on the server.
"""
function push(filename::String, server::Server, server_file::String)
    if islocal(server)
        cp(filename, server_file; force = true)
    else
        out = Pipe()
        err = Pipe()
        # OpenSSH_jll.scp() do scp_exec
            run(pipeline(`scp $filename $(ssh_string(server) * ":" * server_file)`;
                     stdout = out, stderr=err))
        # end
        close(out.in)
        close(err.in)
    end
end

"Executes a command through `ssh`."
function server_command(username, domain, cmd::String)
    out = Pipe()
    err = Pipe()
    if domain == "localhost"
        e = ignorestatus(Cmd(string.(split(cmd))))
        process = run(pipeline(e; stdout = out,
                               stderr = err))
    else
        if Sys.which("ssh") === nothing
            OpenSSH_jll.ssh() do ssh_exec
                process = run(pipeline(ignorestatus(Cmd(["$ssh_exec", "$(username * "@" * domain)",
                                                         string.(split(cmd))...])); stdout = out,
                                       stderr = err))
            end
        else
            process = run(pipeline(ignorestatus(Cmd(["ssh", "$(username * "@" * domain)",
                                                     string.(split(cmd))...])); stdout = out,
                                   stderr = err))
        end
            
    end
    close(out.in)
    close(err.in)

    stdout = read(out, String)
    stderr = read(err, String)
    return (stdout = stdout,
            stderr = stderr,
            exitcode = process.exitcode)
end

server_command(s::Server, cmd) = server_command(s.username, s.domain, cmd)

function has_modules(s::Server)
    try
        server_command(s, "module avail").code == 0
    catch
        false
    end
end

function available_modules(s::Server)
    if has_modules(s)
        return server_command(s, "module avail")
    else
        return String[]
    end
end

function HTTP.request(method::String, s::Server, url, body; kwargs...)
    header = ["USER-UUID" => s.uuid]
    return HTTP.request(method, http_uri(s, url), header, JSON3.write(body);
                        kwargs...)
end

function HTTP.request(method::String, s::Server, url, body::Vector{UInt8}; kwargs...)
    header = ["USER-UUID" => s.uuid]
    return HTTP.request(method, http_uri(s, url), header, body; kwargs...)
end

function HTTP.request(method::String, s::Server, url; connect_timeout = 1, retries = 2,
                      kwargs...)
    header = ["USER-UUID" => s.uuid]

    return HTTP.request(method, http_uri(s, url), header;
                        connect_timeout = connect_timeout, retries = retries, kwargs...)
end

for f in (:get, :put, :post, :head, :patch)
    str = uppercase(string(f))
    @eval function HTTP.$(f)(s::Server, url::AbstractString, args...; kwargs...)
        return HTTP.request("$($str)", s, url, args...; kwargs...)
    end
end

function Base.readdir(s::Server, dir::AbstractString)
    resp = HTTP.get(s, URI(path="/readdir/", query=Dict("path" => abspath(s, dir))))
    return JSON3.read(resp.body, Vector{String})
end

Base.abspath(s::Server, p) = isabspath(p) ? p : joinpath(s, p)

function Base.mtime(s::Server, p)
    if islocal(s)
        return mtime(p)
    else
        resp = HTTP.get(s, URI(path="/mtime/", query=Dict("path" =>  p)))
        return JSON3.read(resp.body, Float64)
    end
end

function Base.filesize(s::Server, p)
    if islocal(s)
        return filesize(p)
    else
        resp = HTTP.get(s, URI(path="/filesize/", query = Dict("path" => p)))
        return JSON3.read(resp.body, Float64)
    end
end

function Base.realpath(s::Server, p)
    if islocal(s)
        return realpath(p)
    else
        resp = HTTP.get(s, URI(path="/realpath/", query=Dict("path" => p)))
        return JSON3.read(resp.body, String)
    end
end
