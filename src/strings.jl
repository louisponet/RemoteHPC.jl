function flagstring(f, v)
    out = ""
    if !occursin("-", f)
        if length(f) == 1
            out *= "-$f"
        else
            out *= "--$f="
        end
    end
    if !(v isa AbstractString) && length(v) > 1
        for v_ in v
            out *=" $v_"
        end
    else
        out *= " $v"
    end
    return out
end

function Base.string(e::Exec)
    direxec = joinpath(e.dir, e.exec)
    out = "$direxec"
    for (f, v) in e.flags
        out *= flagstring(f, v)
    end
    return out
end

function Base.string(c::Calculation)
    out = string(c.exec)
    if !isempty(c.infile)
        out *= " < $(c.infile)"
    end
    if !isempty(c.outfile)
        out *= " > $(c.outfile)"
    end
        
    return out
end



