using REPL.TerminalMenus
using OpenSSH_jll
const SERVER_DIR = config_path("storage/servers")

"""
    Server(name::String, username::String, domain::String, scheduler::Scheduler, mountpoint::String,
           julia_exec::String, jobdir::String, max_concurrent_jobs::Int)
    Server(name::String)

A [`Server`](@ref) represents a remote daemon that has the label `name`. It runs on the server defined by
`username` and `domain`. The requirement is that `ssh` is set up in such a way that `ssh username@domain` is
possible, i.e. ssh-copy-id must have been used to not require passwords while executing `ssh` commands.

a tunnel will be created to guarantee a connection. This is useful in the case that the login node on the remote
server can change.

Calling [`Server`](@ref) with a single `String` will either load the configuration that was previously saved with that label, or go through an interactive setup of a new server.
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
        julia = joinpath(Sys.BINDIR, "julia")
    else
        if interactive
            julia = ask_input(String, "Julia Exec", s.julia_exec)
            if server_command(s.username, s.domain, "which $julia").exitcode != 0
                @warn "$julia, no such file or directory. Remember to install julia on the server either manually or using `RemoteHPC.install_RemoteHPC(s)`."
            end
            julia = julia
        else
            julia = "julia"
        end
    end
    s.julia_exec = julia

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
                    dir = ask_input(String, "Default Jobs directory")
                end
            end
        end

        s.jobdir = dir
        s.max_concurrent_jobs = ask_input(Int, "Max Concurrent Jobs", s.max_concurrent_jobs)
    else
        s.jobdir = hdir
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

    @info "saving server configuration...", s
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

function Server(s::String)
    isempty(s) && return Server(name="")
    t = Server(; name = s)
    if exists(t)
        return load(t)
    end
    # Create new server 
    @info "Creating new Server configuration..."
    if occursin("@", s)
        username, domain = split(s, "@")
        name = ask_input(String, "Please specify the Server's identifying name")
        if exists(Server(; name = name, username = username, domain = domain))
            @warn "A server with $name was already configured and will be overwritten."
        end
    elseif s == "localhost"
        username = get(ENV, "USER", "nouser")
        domain = "localhost"
        name = s
    else
        username = ask_input(String, "Username")
        domain = ask_input(String, "Domain")
        name = s
    end
    @info "Trying to pull existing configuration from $username@$domain..."

    server = load_config(username, domain)
    if server !== nothing
        server.name = name
        server.domain = domain

        change_config = request("Found remote server configuration:\n$server\nIs this correct?",
                                RadioMenu(["yes", "no"]))
        change_config == -1 && return
        if change_config == 2
            configure!(server)
        end

    else
        @info "Couldn't pull server configuration, creating new..."
        server = Server(; name = name, domain = domain, username = username)
        configure!(server)
    end
    save(server)
    return server
end

StructTypes.StructType(::Type{Server}) = StructTypes.Mutable()
islocal(s::Server) = s.domain == "localhost"
local_server() = Server(gethostname())

function install_RemoteHPC(s::Server, julia_exec = nothing)
    # We install the latest version of julia in the homedir
    if julia_exec === nothing
        res = server_command(s, "which julia")
        if res.exitcode != 0
            @info "No julia found in PATH, installing it..."
            t = tempname()
            mkdir(t)
            download("https://julialang-s3.julialang.org/bin/linux/x64/1.8/julia-1.8.2-linux-x86_64.tar.gz",
                     joinpath(t, "julia.tar.gz"))
            push(joinpath(t, "julia.tar.gz"), s, "julia-1.8.2-linux-x86_64.tar.gz")
            rm(t; recursive = true)
            res = server_command(s, "tar -xf julia-1.8.2-linux-x86_64.tar.gz")
            @assert res.exitcode == 0 "Issue unpacking julia executable on cluster, please install julia manually"
            julia_exec = "~/julia-1.8.2/bin/julia"
            @info "julia installed in ~/julia-1.8.2/bin"
        else
            julia_exec = res.stdout[1:end-1]
        end
    end
    @info "Installing RemoteHPC"
    res = server_command(s, "$julia_exec --project=~/.julia/config/RemoteHPC/ -e 'using Pkg; Pkg.add(\"RemoteHPC\");Pkg.build(\"RemoteHPC\")'")
    @assert res.exitcode == 0 "Something went wrong installing RemoteHPC on server, please install manually"

    s.julia_exec = julia_exec
    @info "RemoteHPC installed on remote cluster, try starting the server with `start(server)`."
    return
end

function update_RemoteHPC(s::Server)
    alive = isalive(s)
    if alive
        @info "Server running, killing it first."
        kill(s)
    end
    @info "Updating RemoteHPC"
    res = server_command(s, "$(s.julia_exec) --project=~/.julia/config/RemoteHPC/ -e 'using Pkg; Pkg.update(\"RemoteHPC\")'")
    @assert res.exitcode == 0 "Something went wrong updating RemoteHPC."
    if alive
        @info "Restarting server."
        start(s)
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

function load_config(username, domain)
    hostname = gethostname(username, domain)
    if domain == "localhost"
        return parse_config(read(config_path("storage", "servers", "$hostname.json"),
                                 String))
    else
        t = server_command(username, domain,
                           "cat ~/.julia/config/RemoteHPC/$hostname/storage/servers/$hostname.json")
        if t.exitcode != 0
            return nothing
        else
            return parse_config(t.stdout)
        end
    end
end
function load_config(s::Server)
    if isalive(s)
        return JSON3.read(HTTP.get(s, URI(path="/server/config")).body, Server)
    else
        return load_config(s.username, s.domain)
    end
end

function Base.gethostname(username::AbstractString, domain::AbstractString)
    return split(server_command(username, domain, "hostname").stdout)[1]
end
Base.gethostname(s::Server) = gethostname(s.username, s.domain)
ssh_string(s::Server) = s.username * "@" * s.domain
function http_uri(s::Server, uri = HTTP.URI())
    return HTTP.URI(uri, scheme="http", port=s.port, host = "localhost")
end

function Base.rm(s::Server)
    return ispath(joinpath(SERVER_DIR, s.name * ".json")) &&
           rm(joinpath(SERVER_DIR, s.name * ".json"))
end

function find_tunnel(s)
    return getfirst(x -> occursin("-N -L", x),
                    split(read(pipeline(`ps aux`; stdout = `grep $(ssh_string(s))`), String),
                          "\n"))
end

function destroy_tunnel(s)
    t = find_tunnel(s)
    if t !== nothing
        try
            run(`kill $(split(t)[2])`)
        catch
            nothing
        end
    end
end

function construct_tunnel(s, remote_port)
    OpenSSH_jll.ssh() do ssh_exec
        port, serv = listenany(Sockets.localhost, 0)
        close(serv)
        run(Cmd(`$ssh_exec -o ExitOnForwardFailure=yes -o ServerAliveInterval=60 -N -L $port:localhost:$remote_port $(ssh_string(s))`); wait=false)
        return port
    end
end

function ask_input(::Type{T}, message, default = nothing) where {T}
    if default === nothing
        t = ""
        print(message * ": ")
        while isempty(t)
            t = readline()
        end
    else
        print(message * " (default: $default): ")
        t = readline()
        if isempty(t)
            return default
        end
    end
    if T != String
        return parse(T, t)
    else
        return t
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
        OpenSSH_jll.scp() do scp_exec
            run(pipeline(`$scp_exec -r $(ssh_string(server) * ":" * remote) $path`; stdout = out,
                         stderr = err))
        end
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
        OpenSSH_jll.scp() do scp_exec
            run(pipeline(`$scp_exec $filename $(ssh_string(server) * ":" * server_file)`;
                     stdout = out))
        end
        close(out.in)
        close(err.in)
        @show read(err, String)
    end
end

"Executes a command through `ssh`."
function server_command(username, domain, cmd::String)
    out = Pipe()
    err = Pipe()
    if domain == "localhost"
        process = run(pipeline(ignorestatus(Cmd(string.(split(cmd)))); stdout = out,
                               stderr = err))
    else
        OpenSSH_jll.ssh() do ssh_exec
            process = run(pipeline(ignorestatus(Cmd(["$ssh_exec", "$(username * "@" * domain)",
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

function Base.readdir(s::Server, dir::String)
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
