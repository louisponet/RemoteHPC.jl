using Documenter
using RemoteHPC

makedocs(
    sitename = "RemoteHPC",
    format = Documenter.HTML(),
    modules = [RemoteHPC]
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
#=deploydocs(
    repo = "<repository url>"
)=#
