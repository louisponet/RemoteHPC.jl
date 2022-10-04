using Test
using RemoteHPC
tconfdir = tempname()
RemoteHPC.config_path(p...) = joinpath(tconfdir, p...)

paths = ["jobs",
         "logs/jobs",
         "logs/runtimes",
         "storage/servers",
         "storage/execs",
         "storage/environments"]
for p in paths             
    mkpath(RemoteHPC.config_path(p))
end

redirect_stdin(devnull) do
    redirect_stderr(devnull) do
        redirect_stdout(devnull) do
            RemoteHPC.configure_local(interactive=false)
            t = @async RemoteHPC.julia_main()
        end
    end
end

while !isalive(local_server())
    sleep(0.1)
end

t_jobdir = joinpath(homedir(),tempname())

@testset "database" begin
    exec = RemoteHPC.Exec("test", "cat", "", Dict("f" => 3, "test" => [1, 2, 3], "test2" => "stringtest", "-nk" => 10), ["intel", "intel-mkl"], true, true)
    save(local_server(), exec)
    te = load(local_server(), exec)
    for f in fieldnames(Exec)
        @test getfield(te, f) == getfield(exec, f)
    end
    
    exec = RemoteHPC.Exec("test", "cat", "", Dict(), [], true, false)
    redirect_stderr(devnull) do
        save(local_server(), exec)
    end
   
    e = Environment("test", Dict("N" => 1, "time" => "00:01:01"), Dict("OMP_NUM_THREADS" => 1), "", "", RemoteHPC.Exec(name = "srun", exec="srun"))
    partition = get(ENV, "SLURM_PARTITION", nothing)
    account = get(ENV, "SLURM_ACCOUNT", nothing)
    if partition !== nothing
        e.directives["partition"] = partition
    end
    if account !== nothing
        e.directives["account"] = account
    end            

    save(local_server(), e)
    te = load(local_server(), e)
    for f in fieldnames(Environment)
        @test getfield(te, f) == getfield(e, f)
    end
end
@testset "job" begin
    @testset "creation and save" begin
        exec = load(local_server(), Exec("test"))
        c = [Calculation(exec, "scf.in", "scf.out", true), Calculation(exec, "nscf.in", "nscf.out", true)]
        e = load(local_server(), Environment("test"))
        save(local_server(), t_jobdir, "testjob", e, c)
        @test state(local_server(), t_jobdir) == RemoteHPC.Saved

        td = load(local_server(), t_jobdir)
        @test td.name == "testjob"
        for (c1, c2) in zip(c, td.calculations)
            for f in fieldnames(Calculation)
                @test getfield(c1, f) == getfield(c2, f)
            end
        end
        @test td.environment == e
    end
    @testset "submission and running" begin
        write(local_server(), joinpath(t_jobdir, "scf.in"), "test input")
        write(local_server(), joinpath(t_jobdir, "nscf.in"), "test input2")
        submit(local_server(), t_jobdir)
        while state(local_server(), t_jobdir) != RemoteHPC.Completed
            sleep(0.1)
        end
        @test read(joinpath(t_jobdir, "scf.out"), String) == "test input"
        @test read(joinpath(t_jobdir, "nscf.out"), String) == "test input2"
        exec = load(local_server(), Exec("test"))
        sleep_e = Exec(name="sleep", exec="sleep", input_on_stdin = false, parallel=false)
        c = [Calculation(exec, "scf.in", "scf.out", true), Calculation(exec, "nscf.in", "nscf.out", true), Calculation(sleep_e, "10", "", true)]
        e = load(local_server(), Environment("test"))

           
        submit(local_server(), t_jobdir, "testjob", e, c)
        while state(local_server(), t_jobdir) != RemoteHPC.Running
            sleep(0.1)
        end
        abort(local_server(), t_jobdir)
        @test state(local_server(), t_jobdir) == RemoteHPC.Cancelled
    end
        
end
