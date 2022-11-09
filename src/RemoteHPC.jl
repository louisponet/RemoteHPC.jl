module RemoteHPC
using LoggingExtras
using ThreadPools
using HTTP
using HTTP.URIs: URI
using StructTypes
using Sockets
using JSON3
using UUIDs
using Dates
using ProgressMeter
using SnoopPrecompile
using Base: @kwdef

const CONFIG_DIR = occursin("cache", first(Base.DEPOT_PATH)) ?
                   abspath(Base.DEPOT_PATH[2], "config", "RemoteHPC") :
                   abspath(Base.DEPOT_PATH[1], "config", "RemoteHPC")

config_path(path...) = joinpath(CONFIG_DIR, gethostname(), path...)

function getfirst(f, itr)
    id = findfirst(f, itr)
    id === nothing && return nothing
    return itr[id]
end

include("database.jl")

include("types.jl")
include("schedulers.jl")
include("servers.jl")
include("runtime.jl")
include("api.jl")
include("client.jl")
include("io.jl")

@precompile_all_calls begin
    s = local_server()
    t = "asdfe"
    t2 = "edfasdf"
    e = Exec(; name = t2, exec = "srun")
    e1 = Environment(t, Dict("-N" => 3, "partition" => "default", "time" => "00:01:01"),
                     Dict("OMP_NUM_THREADS" => 1), "", "", e)
    save(e1)
    save(e)
    e1 = load(e1)
    e = load(e)
    calcs = [Calculation(e, "< scf.in > scf.out", true)]
    rm(e1)
    rm(e)
end

export Server, start, restart, local_server, isalive, load, save, submit, abort, state
export Calculation, Environment, Exec, HQ, Slurm, Bash

const LOCAL_SERVER = Ref{Server}()

function __init__()
    s = local_server()
    if isinteractive() && !isalive(s)
        @info "Local server isn't running, starting it"
        start(s)
        LOCAL_SERVER[] = s
    end
end


using TOML

const PACKAGE_VERSION = let
    project = TOML.parsefile(joinpath(pkgdir(@__MODULE__), "Project.toml"))
    VersionNumber(project["version"])
end
# if Base.VERSION >= v"1.4.2"
#     include("precompile.jl")
#     _precompile_()
# end
end# module RemoteHPC
