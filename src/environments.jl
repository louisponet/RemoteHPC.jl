@kwdef struct SlurmEnvironment <: Environment
    name::String
    params::Dict = Dict()
    exports::Dict = Dict()
    preamble::String = ""
    postamble::String = ""
    parallel_exec::Exec = Exec(name="srun", exec="srun")
end

function generate_params(::Type{SlurmEnvironment}, preamble::String)
    
    m = match(r"#SBATCH (.+)\n", preamble)
    params = Dict()
    last = 0 
    while m !== nothing
        s = split(replace(replace(m.captures[1], "-"=> ""), "=" => " "))
        tp = Meta.parse(s[2])
        t = tp isa Symbol || tp isa Expr ? s[2] : tp
        params[s[1]] = t
        last = m.offset + length(m.match) 
        m = match(r"#SBATCH (.+)\n", preamble, last)
    end
    return params, preamble[last:end]
end

function Base.:(==)(e1::SlurmEnvironment, e2::SlurmEnvironment)
    for f in fieldnames(SlurmEnvironment)
        if getfield(e1, f) != getfield(e2, f)
            return false
        end
    end
    return true
end
