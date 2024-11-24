module Paths

# Abstract API
export root, isabsolute # `parents` and `basename` are already in `Base`

export PosixPath, WindowsPath, Path,
    PosixPathBuf, WindowsPathBuf, PathBuf, @p_str

public AbstractPath, PlainPath, SystemPath, separator

include("abstractpaths.jl")
include("path.jl")
include("pathbuf.jl")
include("system.jl")
include("filesystem.jl")

end
