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

# More efficient filesystem mapreduce

"""
    UnsafeLazyReadDir(dir::Path) -> iterator<Tuple{Path, Bool}>

A lazy iterator over the contents of a directory that must be manually cleaned up.

The iterator yields tuples of `(path, isdir)` where `path` is `dir` joined with
the name of a child entry and `isdir` is a boolean indicating whether the entry
is a directory or a symlink to a directory.

Cleanup is performed by calling `uv_fs_req_cleanup` on the `req` pointer and
then freeing the memory allocated for `req` (with `Libc.free`).

This is a helper for a more efficient `MapReducer` implementation for `Path`.
"""
struct UnsafeLazyReadDir
    dir::Path
    req::Ptr{Nothing}
end

function UnsafeLazyReadDir(dir::Path)
    req = Libc.malloc(Base.Filesystem._sizeof_uv_fs)
    UnsafeLazyReadDir(dir, req)
end

Base.eltype(::Type{UnsafeLazyReadDir}) = Tuple{Path, Bool}
Base.IteratorEltype(::Type{<:UnsafeLazyReadDir}) = Base.HasEltype()
Base.IteratorSize(::Type{<:UnsafeLazyReadDir}) = Base.SizeUnknown()

function Base.iterate(rd::UnsafeLazyReadDir)
    err = ccall(:uv_fs_scandir, Int32, (Ptr{Cvoid}, Ptr{Cvoid}, Cstring, Cint, Ptr{Cvoid}),
                C_NULL, rd.req, String(rd.dir), 0, C_NULL)
    err < 0 && Base.uv_error(LazyString("iterate(UnsafeLazyReadDir(", rd.dir, "))"), err)
    iterate(rd, nothing)
end

function Base.iterate(rd::UnsafeLazyReadDir, ::Nothing)
    ent = Ref{Base.Filesystem.uv_dirent_t}()
    err = ccall(:uv_fs_scandir_next, Cint, (Ptr{Cvoid}, Ptr{Base.Filesystem.uv_dirent_t}), rd.req, ent)
    if err != Base.UV_EOF
        name = unsafe_string(ent[].name)
        path = joinpath(rd.dir, Path(GenericPlainPath{Path}(name, 0, 0)))
        dirp = ent[].typ == Base.Filesystem.UV_DIRENT_DIR ||
            (ent[].typ == Base.Filesystem.UV_DIRENT_LINK && isdir(path))
        (path, dirp), nothing
    end
end

function (m::MapReducer)(path::Path, dirp::Bool=isdir(path))
    dirp || return m.leaffn(path)
    childs = UnsafeLazyReadDir(path)
    try
        leafvals = Iterators.map(
            function ((childpath, dirp))
                if dirp
                    m(childpath, true)
                else
                    m.leaffn(childpath)
                end
            end,
            Iterators.filter(
                ((childpath, dirp),) -> !dirp || m.descendif(childpath),
                childs))
        m.mergefn(m.branchfn(path), m.reducefn(leafvals))
    finally
        Base.Filesystem.uv_fs_req_cleanup(childs.req)
        Libc.free(childs.req)
    end
end
