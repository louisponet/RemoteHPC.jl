const CONFIG_DIR = occursin("cache", first(Base.DEPOT_PATH)) ?
                   abspath(Base.DEPOT_PATH[2], "config", "DFControl") :
                   abspath(Base.DEPOT_PATH[1], "config", "DFControl")
const DEPS_DIR = joinpath(dirname(@__DIR__), "deps")

const PYTHONPATH = Sys.iswindows() ? joinpath(DEPS_DIR, "python2", "python") :
                   joinpath(dirname(@__DIR__), "deps", "python2", "bin", "python")

const CIF2CELLPATH = Sys.iswindows() ?
                     joinpath(DEPS_DIR, "python2", "Scripts", "cif2cell") :
                     joinpath(dirname(@__DIR__), "deps", "python2", "bin", "cif2cell")

config_path(path...) = joinpath(CONFIG_DIR, gethostname(), path...)

const RUNNING_JOBS_FILE = config_path("jobs", "running.txt")
const PENDING_JOBS_FILE = config_path("jobs", "pending.txt")
const PENDING_WORKFLOWS_FILE = config_path("workflows", "pending.txt")
const RUNNING_WORKFLOWS_FILE = config_path("workflows", "running.txt")
const QUEUE_FILE = config_path("jobs", "queue.json")
