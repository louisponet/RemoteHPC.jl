using Test
using RemoteHPC
using RemoteHPC.BinaryTraits

@testset "Storable interface" begin
    @test @check(Exec).result
    @test @check(Server).result
    @test @check(Environment).result
end

tconfdir = tempname()
# tconfdir = "/tmp/remotehpc"
if ispath(tconfdir)
    rm(tconfdir; recursive = true)
end
import RemoteHPC: config_path
config_path(p...) = joinpath(tconfdir, p...)

paths = ["jobs",
         "logs/jobs",
         "storage/servers",
         "storage/execs",
         "storage/environments"]
for p in paths
    mkpath(config_path(p))
end

redirect_stdin(devnull) do
    redirect_stderr(devnull) do
        redirect_stdout(devnull) do
            RemoteHPC.configure_local(; interactive = false)
            t = @async RemoteHPC.julia_main(verbose=2)
        end
    end
end

while !isalive(local_server())
    sleep(0.1)
end

const s = local_server()
t_jobdir = tempname()

if s.scheduler isa HQ
    scheds = [s.scheduler, Slurm(), Bash()]
elseif s.scheduler isa Slurm
    scheds = [s.scheduler, Bash()]
else
    scheds = [Bash()]
end
for sched in scheds
    @testset "$sched" begin
        @testset "updating config" begin
            kill(s)
            s.scheduler = sched
            save(s)
            t = @async RemoteHPC.julia_main(verbose=2)
            while !isalive(local_server())
                sleep(0.1)
            end

            st = RemoteHPC.load_config(s)
            @test st.scheduler == sched
        end
        @testset "database" begin
            exec = RemoteHPC.Exec("test", "cat",
                                  Dict("f" => 3, "test" => [1, 2, 3],
                                       "test2" => "stringtest", "-nk" => 10),
                                  ["intel", "intel-mkl"], true)
            save(s, exec)
            te = load(s, exec)
            for f in fieldnames(Exec)
                @test getfield(te, f) == getfield(exec, f)
            end
            exec = RemoteHPC.Exec("test", "cat", Dict(), [], false)
            redirect_stderr(devnull) do
                return save(s, exec)
            end
            e = Environment("test", Dict("N" => 1, "time" => "00:01:01"),
                            Dict("OMP_NUM_THREADS" => 1), "", "",
                            RemoteHPC.Exec(; name = "srun", path = "srun"))
            partition = get(ENV, "SLURM_PARTITION", nothing)
            account = get(ENV, "SLURM_ACCOUNT", nothing)
            if partition !== nothing
                e.directives["partition"] = partition
            end
            if account !== nothing
                e.directives["account"] = account
            end

            save(s, e)
            te = load(s, e)
            for f in fieldnames(Environment)
                @test getfield(te, f) == getfield(e, f)
            end

            es = load(s, Exec("ca"))
            @test length(es) == 1
            es = load(s, Exec(; path = ""))
            @test length(es) == 1
        end
        @testset "job" begin
            @testset "creation and save" begin
                exec = load(s, Exec("test"))
                c = [Calculation(exec, "< scf.in > scf.out", true),
                     Calculation(exec, "< nscf.in > nscf.out", true)]
                e = load(s, Environment("test"))
                save(s, t_jobdir, e, c; name = "testjob")
                @test state(s, t_jobdir) == RemoteHPC.Saved

                td = load(s, t_jobdir)
                @test td.name == "testjob"
                for (c1, c2) in zip(c, td.calculations)
                    for f in fieldnames(Calculation)
                        @test getfield(c1, f) == getfield(c2, f)
                    end
                end
                @test td.environment == e
            end
            @testset "submission and running" begin
                write(s, joinpath(t_jobdir, "scf.in"), "test input")
                write(s, joinpath(t_jobdir, "nscf.in"), "test input2")
                submit(s, t_jobdir)
                while state(s, t_jobdir) != RemoteHPC.Completed
                    sleep(0.1)
                end
                @test read(joinpath(t_jobdir, "scf.out"), String) == "test input"
                @test read(joinpath(t_jobdir, "nscf.out"), String) == "test input2"
                exec = load(s, Exec("test"))
                sleep_e = Exec(; name = "sleep", path = "sleep", parallel = false)
                c = [Calculation(exec, "< scf.in > scf.out", true),
                     Calculation(exec, "< nscf.in > nscf.out", true),
                     Calculation(sleep_e, "10", true)]
                e = load(s, Environment("test"))

                submit(s, t_jobdir, e, c; name = "testjob")
                while state(s, t_jobdir) != RemoteHPC.Running
                    sleep(0.1)
                end
                abort(s, t_jobdir)
                @test state(s, t_jobdir) == RemoteHPC.Cancelled
                rm(s, t_jobdir)
                @test !ispath(s, t_jobdir)
            end
        end
    end
end
@testset "files api" begin
    @test length(readdir(s, config_path())) == 3
    @test filesize(s, config_path("logs/restapi.log")) > 0
    @test mtime(s, config_path("logs/restapi.log")) > 0
    tname = tempname()
    write(s, tname, "test")
    tname2 = tempname()
    symlink(s, tname, tname2)
    @test read(s, tname2, String) == "test"
    rm(s, tname2)
    rm(s, tname)
    @test !ispath(s, tname)
    @test !ispath(s, tname2)
end
