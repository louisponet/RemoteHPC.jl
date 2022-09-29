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
