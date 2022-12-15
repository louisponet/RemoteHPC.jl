@enum JobState BootFail Pending Running Completed Cancelled Deadline Failed NodeFail OutOfMemory Preempted Requeued Resizing Revoked Suspended Timeout Submitted Unknown PostProcessing Saved Configuring Completing

"""
    Exec(;name::String = "",
          path::String = "",
          flags::Dict = Dict(),
          modules::Vector{String} = String[],
          parallel::Bool = true)

Representation of an executable.
As with any [`Storable`](@ref), `name` is used simply as a label to be able to [`load`](@ref) it
from the [`Server`](@ref) where it is stored.

In a job script this will be translated as `<path> <flags>`.

For example:
```julia
Exec(; path="ls", flags=Dict("l" => ""))
# translates into: ls -l
```
## Flags
The `flags` `Dict` is expanded into the jobscript as follows:
```julia
Exec(path="foo", flags = Dict("N"    => 1,
                              "-nk"  => 10,
                              "np"   => "\$NPOOLS",
                              "--t"  => "",
                              "--t2" => 24)
# translates into: foo -N1 -nk 10 --np=\$NPOOLS --t --t2=24
```
## Modules
The `modules` vector gets expanded into `module load` commands:
`modules = ["gcc", "QuantumESPRESSO"]` will lead to `module load gcc, QuantumESPRESSO` in the jobscript.

## Parallel
`parallel` communicates whether the executable should be ran with the parallel executable defined in the
[`Environment`](@ref) that represents the execution environment.
For example:
```julia
# If the Environment of the job is defined as:
Environment(parallel_exec=Exec(path="srun"))
# then the follow Exec:
Exec(path="foo", parallel=true)
# wille be translated into: srun foo
```
"""
@kwdef mutable struct Exec <: Storable
    name::String = ""
    path::String = ""
    flags::Dict = Dict()
    modules::Vector{String} = String[]
    parallel::Bool = true
end

function Exec(d::Dict)
    if haskey(d, :dir)
        Base.depwarn("Constructor with separate `dir` and `exec` will be deprecated. Use one `path` instead.", :Exec)
        return Exec(d[:name], joinpath(d[:dir], d[:exec]), d[:flags], d[:modules], d[:parallel])
    else
        return Exec(d[:name], d[:path], d[:flags], d[:modules], d[:parallel])
    end
end

function Exec(a,b,c,d,e,f)
    Base.depwarn("Constructor with separate `dir` and `exec` will be deprecated. Use one `path` instead.", :Exec)
    return Exec(a, joinpath(b, c), d, e, f)
end

Base.dirname(e::Exec) = dirname(e.path)
exec(e::Exec) = splitpath(e.path)[end]

# Backwards compatibility
function Base.getproperty(e::Exec, name::Symbol)
    if name == :dir
        Base.depwarn("`e.dir` will be deprecated. Use `dirname(e)` instead.", :Exec)
        return dirname(e)
    elseif name == :exec
        Base.depwarn("`e.exec` will be deprecated. Use `exec(e)` instead.", :Exec)
        return exec(e)
    else
        return getfield(e, name)
    end
end

function Base.setproperty!(e::Exec, name::Symbol, v)
    if name == :dir
        Base.depwarn("`e.dir` will be deprecated in favor of `e.path`.", :Exec)
        return setfield!(e, :path, joinpath(v, exec(e)))
    elseif name == :exec
        Base.depwarn("`e.exec` will be deprecated in favor of `e.path`.", :Exec)
        return setfield!(e, :path, joinpath(dirname(e), v))
    else
        return getfield(e, name)
    end
end

function isrunnable(e::Exec)
    # To find the path to then ldd on
    fullpath = Sys.which(e.path)
    if fullpath !== nothing && ispath(fullpath)
        out = Pipe()
        err = Pipe()
        #by definition by submitting something with modules this means the server has them
        if !isempty(e.modules)
            cmd = `echo "source /etc/profile && module load $(join(e.modules, " ")) && ldd $fullpath"`
        else
            cmd = `echo "source /etc/profile && ldd $fullpath"`
        end
        run(pipeline(pipeline(cmd; stdout = ignorestatus(`bash`)); stdout = out,
                     stderr = err))
        close(out.in)
        close(err.in)

        stderr = String(read(err))
        stdout = String(read(out))
        # This basically means that the executable would run
        return !occursin("not found", stdout) && !occursin("not found", stderr)
    else
        return false
    end
end

# Database interface
@assign Exec with Is{Storable}
storage_directory(::Exec) = "execs"



@kwdef struct Calculation
    exec::Exec
    args::String = ""
    run::Bool = true
end

@kwdef mutable struct Environment <: Storable
    name::String = ""
    directives::Dict = Dict()
    exports::Dict = Dict()
    preamble::String = ""
    postamble::String = ""
    parallel_exec::Exec = Exec()
end
@assign Environment with Is{Storable}
storage_directory(::Environment) = "environments"
