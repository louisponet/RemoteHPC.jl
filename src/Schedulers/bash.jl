struct Bash <: Scheduler end

submit_cmd(s::Bash)  = `bash`
