"""
    AbstractFilesystem
"""
abstract type AbstractFilesystem end

"""
    AbstractFileHandle{F<:AbstractFilesystem} <: AbstractHandle

Abstract type for file handles associated with a specific filesystem.

An `AbstractFileHandle{F}` represent an authoritative reference to a resource on
the filesystem `F`.

# Extended help

## AbstractFilesystem Interface

### Read-only filesystem

```julia
open(::AbstractFileHandle; lock, read, write, create, truncate, append) :: IO
stat(::AbstractFileHandle) :: StatStruct
children(::AbstractFileHandle) :: Union{Nothing, iterator of AbstractResolvable{<:AbstractFileHandle}}
```

**Generic derived methods:**

```julia
# Basic nature
ispath(::AbstractFileHandle)     :: Bool
isdir(::AbstractFileHandle)      :: Bool
isfile(::AbstractFileHandle)     :: Bool
# Device-specific kinds
isfifo(::AbstractFileHandle)     :: Bool
issocket(::AbstractFileHandle)   :: Bool
ischardev(::AbstractFileHandle)  :: Bool
isblockdev(::AbstractFileHandle) :: Bool
# Metadata
filemode(::AbstractFileHandle)   :: UInt
filesize(::AbstractFileHandle)   :: Int
mtime(::AbstractFileHandle)      :: Float64
ctime(::AbstractFileHandle)      :: Float64
# Permissions
issetuid(::AbstractFileHandle)   :: Bool
issetgid(::AbstractFileHandle)   :: Bool
issticky(::AbstractFileHandle)   :: Bool
```

### Writeable filesystem

```julia
```
"""
abstract type AbstractFileHandle{F<:AbstractFilesystem, H} <: AbstractHandle{H} end

# API generics

isabsolute(::AbstractFileHandle) = true

for f in (:ispath,
          :isdir,
          :isfile,
          :isfifo,
          :ischardev,
          :isblockdev,
          :issocket,
          :issetuid,
          :issetgid,
          :issticky,
          :uperm,
          :gperm,
          :operm,
          :filemode,
          :filesize,
          :mtime,
          :ctime)
    @eval (Base.$f)(path::AbstractFileHandle)  = ($f)(stat(path))
end

# Generic fallbacks

Base.lstat(h::AbstractFileHandle) = stat(h)
Base.islink(h::AbstractFileHandle) = islink(lstat(h))

# Resolvable -> Handle

# TODO: Emit `depwarn`s telling package authors to work with handles directly

Base.stat(r::AbstractResolvable{<:AbstractFileHandle}) = stat(handle(r))
Base.lstat(r::AbstractResolvable{<:AbstractFileHandle}) = lstat(handle(r))

# Path standard type

"""
    Path (alias for AbstractResolvable{<:AbstractFileHandle})

Abstract type for paths that can be resolved to file handles.
"""
const Path = AbstractResolvable{<:AbstractFileHandle}

# Path: mapreduce

struct MapReducer{BF, LF, MF, RF, DF}
    branchfn::BF
    leaffn::LF
    mergefn::MF
    reducefn::RF
    descendif::DF
    followlinks::Bool
end

(m::MapReducer)(node) = m(node, children(node))

# REVIEW: thread a per-directory context (branchfn's value) down to leaffn/descendif, for paths, depth, and inherited rules
function (m::MapReducer)(node, entries)
    isnothing(entries) && return m.leaffn(node)
    value(entry) = if (m.followlinks || !islink(entry)) && isdir(entry) && m.descendif(entry)
        m(entry)
    else
        m.leaffn(entry)
    end
    peeled = Iterators.peel(entries)
    isnothing(peeled) && return m.leaffn(node)
    first, rest = peeled
    values = Iterators.flatten(((value(first),), Iterators.map(value, rest)))
    m.mergefn(m.branchfn(node), m.reducefn(values))
end

"""
    mapreducepath(branchfn::Function, leaffn::Function, mergefn::Function, reducefn::Function, path::Path; [descendif::Function, followlinks::Bool])
    mapreducepath([branchfn::Function = leaffn], leaffn::Function, reduceop::Function, path::Path; [descendif::Function, followlinks::Bool])

Traverse a filesystem, accumulating mapped values.

The `branchfn -> B` transformation is applied to each node with children, and the
`leaffn -> L` transformation is applied to each leaf node. The results are then
reduced with either `reduceop` or `mergefn(B, reducefn(L...))`.

The traversal is a complete fold of the tree: it cannot stop early, visits
entries in no particular order (so `reducefn`/`reduceop` should be
associative), and does not expose depth. Entries are only guaranteed valid
within the calls made for the directory that contains them; resolve anything
you want to keep (such as a path or `stat`) inside `leaffn`. If `reduceop` is used, it should be a binary function that combines
two leaf values (`reduceop(::L, ::L)`). If `reducefn` is used, it is supplied an
iterator of leaf values.

When using `reduceop`, it is possible to omit `branchfn` for convenience, in
which case `leaffn` is used for both branches and leaves.

# Examples

Count the total number of locations one may reach from a path:

```julia
numdest(path) = mapreducepath(_ -> 1, +, path)
```

Count only the number of branch points under a path:

```julia
numbranches(path) = mapreducepath(_ -> 1, _ -> 0, +, path)
```

List the names of all leaves under a path, accumulating into one vector per
directory:

```julia
leafnames(path) = mapreducepath(_ -> String[], p -> [String(basename(p))], (_, names) -> names,
                                names -> reduce(append!, names; init = String[]), path)
```

Find the most steps one could take starting from a path:

```
maxdepth(path) = mapreducepath(_ -> nothing, _ -> 1, (_, dmax) -> dmax + 1, depths -> maximum(depths, init=0), path)
```
"""
mapreducepath(branchfn::FB, leaffn::FL, mergefn::FM, reducefn::FR, path::Path; descendif::FD = Returns(true), followlinks::Bool = false) where {FB <: Function, FL <: Function, FM <: Function, FR <: Function, FD <: Function} =
    MapReducer(branchfn, leaffn, mergefn, reducefn, descendif, followlinks)(path)

mapreducepath(branchfn::FB, leaffn::FL, op::FO, path::Path; descendif::FD = Returns(true), followlinks::Bool = false) where {FB <: Function, FL <: Function, FO <: Function, FD <: Function} =
    mapreducepath(branchfn, leaffn, op, Base.Fix1(reduce, op), path; descendif, followlinks)

mapreducepath(nodefn::FN, op::FO, path::Path; descendif::FD = Returns(true), followlinks::Bool = false) where {FN <: Function, FO <: Function, FD <: Function} =
    mapreducepath(nodefn, nodefn, op, path; descendif, followlinks)
