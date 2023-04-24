@enum JobState BootFail Pending Running Completed Cancelled Deadline Failed NodeFail OutOfMemory Preempted Requeued Resizing Revoked Suspended Timeout Submitted Unknown PostProcessing Saved Configuring Completing SubmissionError

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

# `configure()` Example
```julia
name::String = "exec_label"
path::String = "/path/to/exec"
flags::Dict{Any, Any} = Dict{Any, Any}("l" => 1, "-np" => 4, "trialname" => "testtrial")
modules::Vector{String} = String["intel","intel-mkl"]
parallel::Bool = false
```

# Example:
```julia
Exec(; path="ls", flags=Dict("l" => ""))
```
translates into `ls -l` in the jobscript.

# Flags
The `flags` `Dict` is expanded into the jobscript as follows:
```julia
Exec(path="foo", flags = Dict("N"    => 1,
                              "-nk"  => 10,
                              "np"   => "\$NPOOLS",
                              "--t"  => "",
                              "--t2" => 24)
# translates into: foo -N1 -nk 10 --np=\$NPOOLS --t --t2=24
```
# Modules
The `modules` vector gets expanded into `module load` commands:
`modules = ["gcc", "QuantumESPRESSO"]` will lead to `module load gcc, QuantumESPRESSO` in the jobscript.

# Parallel
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

exec(e::Exec) = splitdir(e.path)[end]
Base.dirname(e::Exec) = splitdir(e.path)[1]

# Backwards compatibility
function Base.getproperty(e::Exec, name::Symbol)
    if name == :dir
        Base.depwarn("`e.dir` will be deprecated. Use `dirname(e)` instead.", :Exec)
        return dirname(e.path)
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
        return setfield!(e, name, v)
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

"""
    Environment(;name::String,
                 directives::Dict,
                 exports::Dict,
                 preamble::String,
                 postamble::String,
                 parallel_exec::Exec)

Represents and execution environment, i.e. a job script for `SLURM`, `HQ`, etc.
This forms the skeleton of the scripts with the scheduler directives, exports, pre and postambles,
and which executable to use for parallel execution (think `mpirun`, `srun`, etc).

As with any [`Storable`](@ref), `name` is used simply as a label to be able to [`load`](@ref) it
from the [`Server`](@ref) where it is stored.

# `configure()` Example
```julia
name::String = "default",
directives::Dict{Any, Any} = Dict{Any, Any}("time" => "24:00:00", "partition" => "standard", "account" => "s1073", "N" => 4, "ntasks-per-node" => 36, "cpus-per-task" => 1)
exports::Dict{Any, Any} = Dict{Any, Any}("OMP_NUM_THREADS" => 1)
preamble::String = "echo hello"
postamble::String = "echo goodbye"
parallel_exec::Exec = Exec(name="srun", path="srun", flags=Dict("n" => 36))
```

# Example

```julia
Environment(
    name = "default",
    directives = Dict("time" => "24:00:00", "partition" => "standard", "account" => "s1073", "N" => 4, "ntasks-per-node" => 36, "cpus-per-task" => 1)
    exports = Dict("OMP_NUM_THREADS" => 1)
    preamble = "echo hello"
    postamble = "echo goodbye"
    parallel_exec = Exec(name="srun", path="srun", flags=Dict("n" => 36))
)
```

Will be translated into

```bash
#!/bin/bash
# Generated by RemoteHPC
#SBATCH --job-name <will be filled in upon submission> 
#SBATCH --time=24:00:00
#SBATCH --partition=standard
#SBATCH --account=s1073
#SBATCH -N 4
#SBATCH --ntasks-per-node=36
#SBATCH --cpus-per-task=1

export OMP_NUM_THREADS=1

<module load commands specified by Execs will go here>

echo hello

srun -n 36 <parallel Exec 1>
srun -n 36 <parallel Exec 2>
<serial Exec>

echo goodbye
```
"""
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
