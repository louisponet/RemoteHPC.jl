module RemoteHPC

using Base: @kwdef

include("storage.jl")

abstract type Environment end
include("calculations.jl")
include("environments.jl")
include("jobs.jl")
include("io.jl")
include("Schedulers/Schedulers.jl")


end # module RemoteHPC
