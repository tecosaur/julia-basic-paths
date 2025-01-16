# Implementation of filesystem interactions.

# New functions

"""
    cwd() -> Path

Get the current working directory.
"""
cwd() = Path(pwd())

"""
    exists(path::Path) -> Bool

Check if `path` exists on the filesystem.
"""
exists(path::Path) = ispath(String(path))

# New methods of existing functions

for func in (
    # From `stat.jl`
    :ctime, :filemode, :filesize, :gperm, :isblockdev,
    :ischardev, :isdir, :isfifo, :isfile, :islink, :ismount,
    :issetgid, :issetuid, :issocket, :issticky, :lstat,
    :mtime, :operm, :stat, :uperm,
    # From `file.jl`
    :cd, :touch, :readlink, :diskstat,
    # From `filesystem.jl`
    :isexecutable, :isreadable, :iswritable,
    )
    @eval Base.$func(path::Path) = $func(String(path))
end

# From `path.jl`

# REVIEW: I'm not sure whether we should reuse all the methods
# with "path" in the name, or if we should use new functions.
# I like the idea of new functions, but that does cause proliferation
# of names. It might make upgrading/depreciation easier, though.

function Base.splitdrive(path::WindowsPath)
    drive, rest = splitdrive(String(path))
    lastsep = something(findlast(==(separatorbyte(WindowsPath)), codeunits(rest)), 0)
    WindowsPath(drive, ncodeunits(drive), 0, 0),
    WindowsPath(rest, 0, lastsep , 0)
end

Base.realpath(path::Path) = parse(Path, realpath(String(path)))

# TODO: relative path

# From `file.jl`

Base.cd(f::Function, path::Path) = cd(f, String(path))

Base.mkdir(path::Path; mode::Integer = 0o777) =
    mkdir(String(path), mode)

Base.mkpath(path::Path; mode::Integer = 0o777) =
    mkpath(String(path), mode)

Base.rm(path::Path; force::Bool=false, recursive::Bool=false, allow_delayed_delete::Bool=true) =
    rm(String(path); force, recursive, allow_delayed_delete)

Base.cptree(src::Path, dst::Path; force::Bool=false, follow_symlinks::Bool=false) =
    cptree(src.data, dst.data; force, follow_symlinks)

Base.cp(src::Path, dst::Path; force::Bool=false, follow_symlinks::Bool=false) =
    cp(src.data, dst.data; force, follow_symlinks)

Base.mv(src::Path, dst::Path; force::Bool=false) =
    mv(src.data, dst.data; force)

function Base.readdir(path::Path; join::Bool=false, sort::Bool=false)
    children = [Path(child) for child in readdir(String(path); sort)]
    if join
        [joinpath(path, child) for child in children]
    else
        children
    end
end

# TODO walkdir

Base.rename(old::Path, new::Path) = rename(old.data, new.data)

Base.sendfile(src::Path, dst::Path) =
    sendfile(src.data, dst.data)

Base.hardlink(src::Path, dst::Path) =
    hardlink(src.data, dst.data)

Base.symlink(src::Path, dst::Path) =
    symlink(src.data, dst.data)

Base.chmod(path::Path, mode::Integer; recursive::Bool=false) =
    chmod(String(path), mode, recursive)

Base.chown(path::Path, owner::Integer, group::Integer=-1) =
    chown(String(path), owner, group)

# From `cmd.jl`

Base.arg_gen(path::Path) = [String(path)]
