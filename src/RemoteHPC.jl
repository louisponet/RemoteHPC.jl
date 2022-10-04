module RemoteHPC
using LoggingExtras
using ThreadPools
using HTTP
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
    # redirect_stderr(devnull) do
        if !isalive(s)
            @async julia_main()
        end
    # end
    t = "asdfe"
    t2 = "edfasdf"
    e = Exec(name = "$t2", exec="srun")
    e1 = Environment("$t", Dict("-N" => 3, "partition" => "default", "time" => "00:01:01"), Dict("OMP_NUM_THREADS" => 1), "", "", e)
    save(s, e1)
    save(s, e)
    e1 = load(s, e1)
    e = load(s, e)
    calcs = [Calculation(e, "scf.in", "scf.out", true)]
    tdir = tempname()
    save(s, tdir, "test", e1, calcs)
    state(s, tdir)
    load(s, tdir)
    rm(s, tdir)
    rm(s, e1)
    rm(s, e)
end

export Server, start, restart, local_server, isalive, load, save, submit, abort, state
export Calculation, Environment, Exec

# if Base.VERSION >= v"1.4.2"
#     include("precompile.jl")
#     _precompile_()
# end
end# module RemoteHPC
