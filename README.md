# RemoteHPC.jl
[![Build Status](https://github.com/louisponet/RemoteHPC.jl/workflows/CI/badge.svg)](https://github.com/louisponet/RemoteHPC.jl/actions?query=workflow%3ACI)
[![codecov](https://codecov.io/gh/louisponet/RemoteHPC.jl/branch/master/graph/badge.svg?token=PAFMYMVJUT)](https://codecov.io/gh/louisponet/RemoteHPC.jl)

RemoteHPC attempts to wrap all the usual interactions one might have with a remote HPC cluster in a restAPI webserver that runs on the frontend of the cluster.

## Features
- Store locally connection information to remote servers using `Server`
- Remotely store information for available executables and execution environments using `save(server, Exec(...))` and `save(server, Environment(...))`.
- Load remotely stored info using `load(server, Exec("<label>"))` and `load(server, Environment("<label>"))`.
- Represent a line in a jobscript using `Calculation(exec::Exec, infile::String, outfile::String, run::Bool, parallel::Bool)`.
- Save and submit a job with `save(server, jobdir, jobname, environment, calculations)` and `submit(server, jobdir)` or combine both steps with `submit(server, jobdir, jobname, environment, calculations)`.
- The state of a job can be retrieved by `state(server, jobdir)`.
- A job can be aborted using `abort(server, jobdir)`.
- Support for running jobs with `SLURM`, `HyperQueue`, or `Bash`.
- remote file operations: `read`,`write`, `rm`, `mtime`, `link`, etc.
- Starting a remote server with `start(server)` and automatic creation of ssh tunnels by specifying `server.local_tunnel`, useful when the frontend of a cluster is behind a proxy.

