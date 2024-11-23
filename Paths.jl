module Paths

# Some overall comments:
# 1. I think there are too many exported types. I don't see much use in the mutable
# types. IMO just keep it `AbstractPath`, `PosixPath` and `WindowsPath`.
# 2. I think all these types can be represented by just a buffer (and maybe a
# start and stop index, so they can share the buffer).
# However, as long as the internal state is kept private, that can always be
# changed later.
# 3. There are a bunch of edge cases I've commented throughout your code.
# See the comments and the small testset I made.
# 4. I agree with your design that all paths are always normalized, so
# the normpath function does not need to be there.

# Why not reuse `isabspath`? Or `isabs`? `isabsolute` is a new symbol exported
# with an even longer name than `isabspath`
export AbstractPath, root, parent, basename, isabsolute

# Do we need to export the abstract types? I suppose only people who want to make
# new path types need them - a very small minority.
# For the rest, it's just more types to learn. We can just mark them public.
export PlainPath, SystemPath, PosixPath, WindowsPath, Path,
    PosixPathBuf, WindowsPathBuf, PathBuf, @p_str

public separator

include("api.jl")
include("path.jl")
include("pathbuf.jl")
include("system-paths.jl")

end
