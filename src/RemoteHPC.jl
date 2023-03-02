module RemoteHPC
using LoggingExtras
using Logging
using Dates

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
using Pkg
using InteractiveUtils
using BinaryTraits
using DataStructures
using Oxygen

const CONFIG_DIR = occursin("cache", first(Base.DEPOT_PATH)) ?
                   abspath(Base.DEPOT_PATH[2], "config", "RemoteHPC") :
                   abspath(Base.DEPOT_PATH[1], "config", "RemoteHPC")


config_path(path...) = joinpath(CONFIG_DIR, gethostname(), path...)

function getfirst(f, itr)
    id = findfirst(f, itr)
    id === nothing && return nothing
    return itr[id]
end

const DEFAULT_PRIORITY = 5

include("utils.jl")
include("logging.jl")
include("database.jl")

include("types.jl")
include("schedulers.jl")
include("servers.jl")
const LOCAL_SERVER = Ref{Server}()

include("runtime.jl")
include("api.jl")
include("client.jl")
include("io.jl")


@precompile_all_calls begin
    s = local_server()
    isalive(local_server())
    t = "asdfe"
    t2 = "edfasdf"
    e = Exec(; name = t2, path = "srun")
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


export Server, start, restart, local_server, isalive, load, save, submit, abort, state, configure, priority!, check_connections
export Calculation, Environment, Exec, HQ, Slurm, Bash
export exec


function __init__()
    LOCAL_SERVER[] = local_server()
    init_traits(@__MODULE__)
end

using TOML

const PACKAGE_VERSION = let
    project = TOML.parsefile(joinpath(pkgdir(@__MODULE__), "Project.toml"))
    VersionNumber(project["version"])
end

end# module RemoteHPC
