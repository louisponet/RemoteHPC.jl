@enum JobState BootFail Pending Running Completed Cancelled Deadline Failed NodeFail OutOfMemory Preempted Requeued Resizing Revoked Suspended Timeout Submitted Unknown PostProcessing Saved

mutable struct Job
    name::String
    id::Int
    dir::String
    script::String
    environment::Environment
    state::JobState
end
    
