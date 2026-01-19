module Paths

export root, isabsolute # `parents` and `basename` are already in `Base`

export @p_str, Path, PosixPath, WindowsPath, handle, AbstractFileHandle, mapreducepath

public AbstractResolvable, AbstractHandle, AbstractPath, AbstractFilesystem

include("interfaces/abstracthandles.jl")
include("interfaces/abstractpaths.jl")
include("interfaces/abstractfilesystem.jl")

include("plainpath.jl")
include("genericpath.jl")
include("systems.jl")

include("filesystems/local.jl")

include("macro.jl")

end
