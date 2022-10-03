@enum JobState BootFail Pending Running Completed Cancelled Deadline Failed NodeFail OutOfMemory Preempted Requeued Resizing Revoked Suspended Timeout Submitted Unknown PostProcessing Saved Configuring Completing

"""
    Exec(;name::String = "",
          exec::String = "",
          dir::String = "",
          flags::Dict = Dict(),
          modules::Vector{String} = String[],
          parallel::Bool = true)

Representation of an `executable` that will run the [`Calculation`](@ref Calculation).
Basically `dir/exec --<flags>` inside a job script.

    Exec(exec::String, dir::String, flags::Pair{Symbol}...)

Will first transform `flags` into a `Vector{ExecFlag}`, and construct the [`Exec`](@ref). 
"""
@kwdef mutable struct Exec <: Storable
    name::String = ""
    exec::String = ""
    dir::String = ""
    flags::Dict = Dict()
    modules::Vector{String} = String[]
    input_on_stdin::Bool = true
    parallel::Bool = true
end
Exec(str::String;kwargs...) = Exec(name=str; kwargs...)
Base.:(==)(e1::Exec, e2::Exec) = e1.name == e2.name
storage_directory(::Exec) = "execs"
StructTypes.StructType(::Exec) = StructTypes.Mutable()

function isrunnable(e::Exec)
    # To find the path to then ldd on
    fullpath = !isempty(e.dir) ? joinpath(e.dir, e.exec) : Sys.which(e.exec)
    if fullpath !== nothing && ispath(fullpath)
        out = Pipe()
        err = Pipe()
        #by definition by submitting something with modules this means the server has them
        if !isempty(e.modules)
            cmd = `echo "source /etc/profile && module load $(join(e.modules, " ")) && ldd $fullpath"`
        else
            cmd = `echo "source /etc/profile && ldd $fullpath"`
        end
        run(pipeline(pipeline(cmd, stdout=ignorestatus(`bash`)), stdout = out, stderr=err))
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

@kwdef struct Calculation
    exec::Exec
    infile::String = ""
    outfile::String = ""
    run::Bool = true
end
StructTypes.StructType(::Calculation) = StructTypes.Mutable()

@kwdef struct Environment <: Storable
    name::String = ""
    directives::Dict = Dict()
    exports::Dict = Dict()
    preamble::String = ""
    postamble::String = ""
    parallel_exec::Exec = Exec()
end
Environment(name::String; kwargs...) = Environment(name=name; kwargs...)
Base.:(==)(e1::Environment, e2::Environment) = e1.name == e2.name
storage_directory(::Environment) = "environments"


StructTypes.StructType(::Environment) = StructTypes.Mutable()
