const CONFIG_DIR = occursin("cache", first(Base.DEPOT_PATH)) ?
                   abspath(Base.DEPOT_PATH[2], "config", "RemoteHPC") :
                   abspath(Base.DEPOT_PATH[1], "config", "RemoteHPC")

config_path(path...) = joinpath(CONFIG_DIR, gethostname(), path...)

paths = ["jobs",
         "logs/jobs",
         "logs/runtimes",
         "storage/servers",
         "storage/execs",
         "storage/environments"]
for p in paths
    mkpath(config_path(p))
end

using UUIDs, JSON3
using Pkg
"""
    configure_local()

Runs through interactive configuration of the local [`Server`](@ref).
"""
function configure_local()
    host = gethostname()
    spath = config_path("storage/servers/$host.json")
    if !ispath(spath)
        scheduler = nothing
        if haskey(ENV, "DFC_SCHEDULER")
            sched = ENV["DFC_SCHEDULER"]
            if occursin("hq", lowercase(sched))
                cmd = get(ENV, "DFC_SCHEDULER_CMD", "hq")
                scheduler = (type = "hq", server_command = cmd, allocs = String[])
            elseif lowercase(sched) == "slurm"
                scheduler = (type = "slurm",)
            else
                error("Scheduler $sched not recognized please set a different DFC_SCHEDULER environment var.")
            end
        end

        for t in ("hq", "sbatch")
            if Sys.which(t) !== nothing
                scheduler = t == "hq" ?
                            (type = "hq", server_command = "hq", allocs = String[]) :
                            (type = "slurm",)
            end
        end
        scheduler = scheduler === nothing ? (type = "bash",) : scheduler
        user = get(ENV, "USER", "noname")
        JSON3.write(spath,
                    (name = host, username = user, domain = "localhost",
                     julia_exec = joinpath(Sys.BINDIR, "julia"), scheduler = scheduler,
                     jobdir = homedir(),
                     max_concurrent_jobs = 100, uuid = string(uuid4())))
    end
end
configure_local()
Pkg.activate(CONFIG_DIR)
Pkg.add("RemoteHPC")
