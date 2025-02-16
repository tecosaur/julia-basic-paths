module Paths

# Abstract API
export root, isabsolute # `parents` and `basename` are already in `Base`

export PosixPath, WindowsPath, PurePath, Path,
    PosixPathBuf, WindowsPathBuf, PathBuf, @p_str, mapreducepath

export children, cwd

public AbstractPath, PlainPath, PlatformPath, separator

include("abstractpaths.jl")
include("path.jl")
include("pathbuf.jl") # Experimental
include("system.jl")
include("filesystem.jl")

# Extra experimental
include("concrete.jl")

end
