mutable struct MemoryFilesystem <: AbstractFilesystem
    const inodes::Dict{UInt, Vector{UInt8}}
    const nlinks::Dict{UInt, UInt}
    const files::Dict{UInt, UInt}
    const dirs::Dict{UInt, Vector{UInt}}
    const symlinks::Dict{UInt, PosixPath}
    const names::Dict{UInt, String}
    const parents::Dict{UInt, UInt}
    const permissions::Dict{UInt, UInt16}
    const mtimes::Dict{UInt, Float64}
    const ctimes::Dict{UInt, Float64}
    const opened::Dict{UInt, UInt}
    const lock::ReentrantLock
    nextnode::UInt
end

function MemoryFilesystem()
    inodes = Dict{UInt, Vector{UInt8}}()
    nlinks = Dict{UInt, UInt}()
    files = Dict{UInt, UInt}()
    dirs = Dict{UInt, Vector{UInt}}(1 => UInt[])
    symlinks = Dict{UInt, PosixPath}()
    names = Dict{UInt, String}(1 => "/")
    parents = Dict{UInt, UInt}(1 => 1)
    permissions = Dict{UInt, UInt16}(1 => 0o40775) # drwxrwxr-x
    ctimes = Dict{UInt, Float64}(1 => time())
    mtimes = Dict{UInt, Float64}(1 => ctimes[1])
    opened = Dict{UInt, UInt}()
    MemoryFilesystem(inodes, nlinks, files, dirs, symlinks, names,
                     parents, permissions, mtimes, ctimes, opened, ReentrantLock(), 2)
end

function Base.show(io::IO, fs::MemoryFilesystem)
    nelts = length(fs.files) + length(fs.dirs) + length(fs.symlinks)
    print(io, "MemoryFilesystem(", nelts, " entries, ", length(fs.opened), " open)")
end

mutable struct MemoryFileHandle <: AbstractFileHandle{MemoryFilesystem, MemoryFileHandle}
    const fs::MemoryFilesystem
    fd::UInt
    inode::UInt
end

filesystem(h::MemoryFileHandle) = h.fs

struct MemoryFilepath <: PlainPath{MemoryFileHandle}
    fs::MemoryFilesystem
    path::PosixPath
end

MemoryFilepath(fs::MemoryFilesystem, args...) = MemoryFilepath(fs, PosixPath(args...))

separator(::MemoryFilepath) = separator(PosixPath)
genericpath(path::MemoryFilepath) = genericpath(path.path)

filesystem(p::MemoryFilepath) = p.fs

function handle(path::MemoryFilepath)
    node = UInt(1)
    isabsolute(path) || throw(ArgumentError("Can only handle absolute paths"))
    @lock path.fs.lock begin
        for segment in path
            haskey(path.fs.dirs, node) || throw(ArgumentError("Path does not exist"))
            children = path.fs.dirs[node]
            for child in children
                if path.fs.names[child] == segment
                    node = child
                    break
                end
            end
        end
        path.fs.opened[node] = get(path.fs.opened, node, 0) + 1
    end
    inode = get(path.fs.files, node, zero(UInt))
    MemoryFileHandle(path.fs, node, inode)
end

function Base.close(hdl::MemoryFileHandle)
    iszero(hdl.fd) && return
    @lock paths.fs.lock begin
        nowopen = paths.fs.opened[hdl.fd] - 1
        if iszero(nowopen)
            delete!(paths.fs.opened, hdl.fd)
        else
            paths.fs.opened[hdl.fd] = nowopen
        end
    end
    hdl.fd = zero(UInt)
end

# Abstract filesystem API

function Base.open(hdl::MemoryFileHandle;
                   lock = true,
                   read :: Union{Bool,Nothing} = nothing,
                   write:: Union{Bool,Nothing} = nothing,
                   create :: Union{Bool,Nothing} = nothing,
                   truncate :: Union{Bool,Nothing} = nothing,
                   append :: Union{Bool,Nothing} = nothing)
    iszero(hdl.inode) && throw(ArgumentError("Cannot open non-file"))
    iszero(hdl.fd) && throw(ArgumentError("Cannot open closed file handle"))
    IOBuffer(hdl.data; read, write, append, truncate)
end

function Base.stat(hdl::MemoryFileHandle)
    kind, size = if haskey(hdl.fs.files, hdl.node)
        0x8000, length(get(hdl.fs.inodes, hdl.inode, UInt8[]))
    elseif haskey(hdl.fs.dirs, hdl.node)
        0x4000, sizeof(UInt) * length(get(hdl.fs.dirs, hdl.fd, UInt))
    elseif haskey(hdl.fs.symlinks, hdl.node)
        0xa000, sizeof(UInt)
    else
        0x0000, 0
    end
    Base.Filesystem.StatStruct(
        "<MemoryFileHandle>",
        1, # dev
        ifelse(iszero(hdl.inode), hdl.fd, hdl.inode), # ino
        kind + hdl.fs.permissions[hdl.node], # mode
        get(hdl.fs.nlinks, hdl.inode, hdl.fd), # nlink
        0, # uid
        0, # gid
        0, # rdev
        length(get(hdl.fs.inodes, hdl.inode, UInt8[])) + # size
            sizeof(UInt) * length(get(hdl.fs.dirs, hdl.fd, UInt)),
        8 * sizeof(UInt), # blocksize
        size, # blocks
        hdl.fs.mtimes[hdl.node], # mtime
        hdl.fs.ctimes[hdl.node], # ctime
        0)
end

# TODO: Introduce dir entry type
function children(hdl::MemoryFileHandle)
    if iszero(hdl.inode)
        map(hdl.fs.dirs[hdl.node]) do child
            MemoryFileHandle(hdl.fs, child, get(hdl.fs.files, child, zero(UInt)))
        end
    end
end
