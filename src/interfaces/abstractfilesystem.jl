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
children(::AbstractFileHandle) :: Union{Nothing, <:AbstractResolvable{<:AbstractFileHandle}}
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

function (m::MapReducer)(path::Path)
    childs = children(path)
    childstate = iterate(childs)
    isnothing(childstate) && return m.leaffn(path)
    # Obtain first value
    thischild, childitr = childstate
    leafacc = if islink(thischild)
        if m.followlinks && isdir(thischild)
            m(thischild)
        else
            m.leaffn(thischild)
        end
    elseif isdir(thischild) && m.descendif(thischild)
        m(thischild)
    else
        m.leaffn(thischild)
    end
    applicable(close, thischild) && close(thischild)
    # Reduce remaining values
    childstate = iterate(childs, childitr)
    while !isnothing(childstate)
        thischild, childitr = childstate
        childstate = iterate(childs, childitr)
        leafval = if islink(thischild)
            if m.followlinks && isdir(thischild)
                m(thischild)
            else
                m.leaffn(thischild)
            end
        elseif isdir(thischild) && m.descendif(thischild)
            m(thischild)
        else
            m.leaffn(thischild)
        end
        applicable(close, thischild) && close(thischild)
        leafacc = m.reducefn(leafacc, leafval)
    end
    # Merge to final value
    m.mergefn(m.branchfn(path), leafacc)
end

"""
    mapreducepath(branchfn::Function, leaffn::Function, mergefn::Function, reducefn::Function, path::Path; [descendif::Function])
    mapreducepath([branchfn::Function = leaffn], leaffn::Function, reduceop::Function, path::Path; [descendif::Function])

Traverse a filesystem, accumulating mapped values.

The `branchfn -> B` transformation is applied to each node with children, and the
`leaffn -> L` transformation is applied to each leaf node. The results are then
reduced with either `reduceop` or `mergefn(B, reducefn(L...))`.

The traversal order is undefined, and so `reducefn`/`reduceop` should be
associative. If `reduceop` is used, it should be a binary function that combines
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

List all possible destinations from a path:

```julia
alldests(path) = mapreducepath(identity, identity, vcat, collect, path)
```

Find the most steps one could take starting from a path:

```
maxdepth(path) = mapreducepath(_ -> nothing, _ -> 1, (_, dmax) -> dmax + 1, depths -> maximum(depths, init=0), path)
```
"""
function mapreducepath(branchfn::FB, leaffn::FL, mergefn::FM, reducefn::FR, path::Path; descendif::FD = Returns(true)) where {FB <: Function, FL <: Function, FM <: Function, FR <: Function, FD <: Function}
    mr = MapReducer(branchfn, leaffn, mergefn, reducefn, descendif, false)
    mr(path)
end

mapreducepath(branchfn::FB, leaffn::FL, op::FO, path::Path; descendif::FD = Returns(true)) where {FB <: Function, FL <: Function, FO <: Function, FD <: Function} =
    mapreducepath(branchfn, leaffn, op, op, path; descendif)

mapreducepath(nodefn::FN, op::FO, path::Path; descendif::FD = Returns(true)) where {FN <: Function, FO <: Function, FD <: Function} =
    mapreducepath(nodefn, nodefn, op, path; descendif)
