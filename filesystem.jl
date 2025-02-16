# Implementation of filesystem interactions.

# New functions

# cwd() = PurePath(pwd())

"""
    exists(path::PurePath) -> Bool

Check if `path` exists on the filesystem.
"""
exists(path::PurePath) = ispath(String(path))

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
    @eval (Base.$func)(path::PurePath) = ($func)(String(path))
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

Base.realpath(path::PurePath) = parse(PurePath, realpath(String(path)))

# TODO: relative path

# From `file.jl`

Base.cd(f::Function, path::PurePath) = cd(f, String(path))

Base.mkdir(path::PurePath; mode::Integer = 0o777) =
    mkdir(String(path), mode)

Base.mkpath(path::PurePath; mode::Integer = 0o777) =
    mkpath(String(path), mode)

Base.rm(path::PurePath; force::Bool=false, recursive::Bool=false, allow_delayed_delete::Bool=true) =
    rm(String(path); force, recursive, allow_delayed_delete)

Base.cptree(src::PurePath, dst::PurePath; force::Bool=false, follow_symlinks::Bool=false) =
    cptree(String(src), String(dst); force, follow_symlinks)

Base.cp(src::PurePath, dst::PurePath; force::Bool=false, follow_symlinks::Bool=false) =
    cp(String(src), String(dst); force, follow_symlinks)

Base.mv(src::PurePath, dst::PurePath; force::Bool=false) =
    mv(String(src), String(dst); force)

function Base.readdir(path::PurePath; join::Bool=false, sort::Bool=false)
    children = [PurePath(child) for child in readdir(String(path); sort)]
    if join
        [joinpath(path, child) for child in children]
    else
        children
    end
end

# TODO walkdir

Base.rename(old::PurePath, new::PurePath) = rename(String(old), String(new))

Base.sendfile(src::PurePath, dst::PurePath) =
    sendfile(String(src), String(dst))

Base.hardlink(src::PurePath, dst::PurePath) =
    hardlink(String(src), String(dst))

Base.symlink(src::PurePath, dst::PurePath) =
    symlink(String(src), String(dst))

Base.chmod(path::PurePath, mode::Integer; recursive::Bool=false) =
    chmod(String(path), mode, recursive)

Base.chown(path::PurePath, owner::Integer, group::Integer=-1) =
    chown(String(path), owner, group)

# From `cmd.jl`

Base.arg_gen(path::PurePath) = [String(path)]

# More efficient filesystem mapreduce

"""
    UnsafeLazyReadDir(dir::PurePath) -> iterator<Tuple{PurePath, Bool}>

A lazy iterator over the contents of a directory that must be manually cleaned up.

The iterator yields tuples of `(path, isdir)` where `path` is `dir` joined with
the name of a child entry and `isdir` is a boolean indicating whether the entry
is a directory or a symlink to a directory.

Cleanup is performed by calling `uv_fs_req_cleanup` on the `req` pointer and
then freeing the memory allocated for `req` (with `Libc.free`).

This is a helper for a more efficient `MapReducer` implementation for `PurePath`.
"""
struct UnsafeLazyReadDir
    dir::PurePath
    req::Ptr{Nothing}
end

function UnsafeLazyReadDir(dir::PurePath)
    req = Libc.malloc(Base.Filesystem._sizeof_uv_fs)
    UnsafeLazyReadDir(dir, req)
end

Base.eltype(::Type{UnsafeLazyReadDir}) = Tuple{PurePath, Bool}
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
        path = joinpath(rd.dir, PurePath(GenericPlainPath{PurePath}(name, 0, 0)))
        dirp = ent[].typ == Base.Filesystem.UV_DIRENT_DIR ||
            (ent[].typ == Base.Filesystem.UV_DIRENT_LINK && isdir(path))
        (path, dirp), nothing
    end
end

function (m::MapReducer)(path::PurePath, dirp::Bool=isdir(path))
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
