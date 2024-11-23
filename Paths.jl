module Paths

export AbstractPath, root, parent, basename, isabsolute

export PlainPath, SystemPath, PosixPath, WindowsPath, Path,
    PosixPathBuf, WindowsPathBuf, PathBuf, @p_str

public separator

include("api.jl")
include("path.jl")
include("pathbuf.jl")
include("system-paths.jl")

end
