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
@kwdef mutable struct Exec
    name::String = ""
    exec::String = ""
    dir::String = ""
    flags::Dict = Dict()
    modules::Vector{String} = String[]
    input_redirect::Bool = true
    parallel::Bool = true
end

function Base.:(==)(e1::Exec, e2::Exec)
    for f in fieldnames(Exec)
        if getfield(e1, f) != getfield(e2, f)
            return false
        end
    end
    return true
end

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

function Base.:(==)(e1::Calculation, e2::Calculation)
    for f in fieldnames(Calculation)
        if getfield(e1, f) != getfield(e2, f)
            return false
        end
    end
    return true
end
