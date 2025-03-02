"""
    AbstractPath{T}

Abstract type for *paths*, defined by a series of segments of type `T` that
describe a location.

This can be thought of as an analogue of `Vector{T}`, with extra semantics, an
in fact can be iterated over and `collect`ed into a `Vector{T}` .

See also: [`PlainPath`](@ref).

# Interface

```
root(path::AbstractPath{T}) -> Union{AbstractPath{T}, Nothing}
parent(path::AbstractPath{T}) -> Union{AbstractPath{T}, Nothing}
basename(path::AbstractPath{T}) -> T
length(path::AbstractPath{T}) -> Int
iterate(path::AbstractPath{T}) -> T...
joinpath(a::AbstractPath{T}, b::AbstractPath{T}) -> AbstractPath{T}
```

Optional methods, with generic implementations derived
from the base interface:

```
isabsolute(path::AbstractPath{T}) -> Bool
```
"""
abstract type AbstractPath{T} end

"""
    root(path::AbstractPath{T}) -> Union{AbstractPath{T}, Nothing}

Return the root of the `path`, if it exists.

!!! note
     Part of the [`AbstractPath`](@ref) interface.
"""
function root end

@doc """
    parent(path::AbstractPath{T}) -> Union{AbstractPath{T}, Nothing}

Return the immediate parent of `path`, if it exists.

!!! note
     Part of the [`AbstractPath`](@ref) interface.
""" Base.parent

@doc """"
    children(path::AbstractPath{T}) -> Union{iterable<AbstractPath{T}>, Nothing}

Return an iterable of the children of `path`, if it has any.

!!! note
     Part of the [`AbstractPath`](@ref) interface.
"""
function children end

@doc """
    basename(path::AbstractPath{T}) -> T

Return the terminal component of `path`.

!!! note
     Part of the [`AbstractPath`](@ref) interface.
""" Base.basename

Base.eltype(::Type{<:AbstractPath{T}}) where {T} = T

# AbstractPath API: optional methods

"""
    isabsolute(path::AbstractPath) -> Bool

Return `true` if `path` is absolute, `false` otherwise.

!!! note
     Optional component of the [`AbstractPath`](@ref) interface.
"""
isabsolute(path::AbstractPath) = !isnothing(root(path))

# AbstractPath API: Mapreduce

struct MapReducer{BF, LF, MF, RF, DF}
    branchfn::BF
    leaffn::LF
    mergefn::MF
    reducefn::RF
    descendif::DF
end

function (m::MapReducer)(path::AbstractPath, childs = children(path))
    isnothing(childs) && return m.leaffn(path)
    leafvals = Iterators.map(
        function ((child, cchilds))
            if isnothing(cchilds)
                m.leaffn(child)
            else
                m(child, cchilds)
            end
        end,
        Iterators.filter(
            ((child, cchilds),) -> !isnothing(cchilds) || m.descendif(child),
            Iterators.map(c -> (c, children), childs)))
    m.mergefn(m.branchfn(path), m.reducefn(leafvals))
end

"""
    mapreduce(branchfn::Function, leaffn::Function, mergefn::Function, reducefn::Function, path::AbstractPath; [descendif::Function])
    mapreduce([branchfn::Function = leaffn], leaffn::Function, reduceop::Function, path::AbstractPath; [descendif::Function])

Traverse a path, accumulating mapped values.

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
function mapreducepath(branchfn::FB, leaffn::FL, mergefn::FM, reducefn::FR, path::AbstractPath; descendif::FD = Returns(true)) where {FB <: Function, FL <: Function, FM <: Function, FR <: Function, FD <: Function}
    mr = MapReducer(branchfn, leaffn, mergefn, reducefn, descendif)
    mr(path)
end

function mapreducepath(branchfn::FB, leaffn::FL, op::FO, path::AbstractPath; descendif::FD = Returns(true)) where {FB <: Function, FL <: Function, FO <: Function, FD <: Function}
    fnret = Core.Compiler.return_type(leaffn, Tuple{typeof(path)})
    reducer = if applicable(zero, fnret)
        leaves -> reduce(op, leaves, init=zero(fnret))
    else
        leaves -> reduce(op, leaves)
    end
    mapreducepath(branchfn, leaffn, op, reducer, path; descendif)
end

function mapreducepath(nodefn::FN, op::FO, path::AbstractPath; descendif::FD = Returns(true)) where {FN <: Function, FO <: Function, FD <: Function}
    mapreducepath(nodefn, nodefn, op, path; descendif)
end

# ---------------------
# PlainPath + generic implementation
# ---------------------

"""
    PlainPath <: AbstractPath{SubString{String}}

A `PlainPath` is composed of string segments separated by a particular (ASCII)
character, and no more than $(2^16 - 1) bytes long.

# Interface

```
separator(::Type{<:PlainPath}) -> Char
String(path::PlainPath) -> String
```

You can skip implementing the `String` method if you implement
the generic backed methods:

```
genericpath(path::PlainPath) -> GenericPlainPath | GenexicPlainPathBuf
T(path::GenericPlainPath{T}) -> T
T(path::GenericPlainPathBuf{T}) -> T
```

By implementing these methods, the [`AbstractPath`](@ref) interface is also
implemented by fallback `PlainPath` methods that assume generic backing.
Otherwise, you must implement the `AbstractPath` interface.

Optionally, a `PlainPath` can be extended with the concept of self and parent
reference segments:
```
pseudoself(::Type{<:PlainPath}) -> String
pseudoparent(::Type{<:PlainPath}) -> String
```
"""
abstract type PlainPath <: AbstractPath{SubString{String}} end

"""
    separator(::Type{<:PlainPath}) -> Char
    separator(::PlainPath) -> Char

Return the separator used in paths of the given type.

It is assumed that the separator is exactly one byte long.

!!! note
     Part of the [`PlainPath`](@ref) interface.
"""
separator(::TP) where {TP <: PlainPath} = separator(TP)

"""
    separatorbyte(::Type{<:PlainPath}) -> UInt8

Return the separator byte used in paths of the given type.

!!! warning
     This is a helper method for efficient generic implementations
     of [`PlainPath`](@ref), and is not intended for general use.
"""
separatorbyte(::Type{TP}) where {TP <: PlainPath} = UInt8(separator(TP))

"""
    pseudoself(::Type{<:PlainPath}) -> Union{String, Nothing}

Return the self-reference segment for paths of the given type, if it exists.
"""
pseudoself(::Type{<:PlainPath}) = nothing

"""
    pseudoparent(::Type{<:PlainPath}) -> Union{String, Nothing}

Return the parent-reference segment for paths of the given type, if it exists.
"""
pseudoparent(::Type{<:PlainPath}) = nothing

# Exceptions

abstract type PathException{T} <: Exception end

struct InsufficientParents{T <: AbstractPath} <: PathException{T}
    path::T
    needed::Int
end

function Base.showerror(io::IO, e::InsufficientParents{T}) where {T}
    nth(n::Int) = if n % 10 == 1
        "st"
    elseif n % 10 == 2
        "nd"
    elseif n % 10 == 3
        "rd"
    else "th" end
    if e.needed == 1
        print(io, "Tried to acquire the parent of a path with no parent: $(string(e.path)).")
    else
        print(io, "Tried to acquire the $(e.needed)$(nth(e.needed)) parent of the path $(string(e.path)), which only has $(length(e.path)-1) parents.")
    end
end

struct EmptyPath{T <: AbstractPath} <: PathException{T} end

struct InvalidSegment{T <: PlainPath} <: PathException{T}
    segment::String
    issue::Symbol
    particular::Union{Nothing, Char, String}
    InvalidSegment{T}(segment::AbstractString, issue::Symbol, particular::Union{Nothing, Char, String}) where {T <: PlainPath} =
        new{T}(String(segment), issue, particular)
end

InvalidSegment{T}(segment, issue) where {T <: PlainPath} =
    InvalidSegment{T}(segment, issue, nothing)

function Base.showerror(io::IO, e::InvalidSegment{T}) where {T}
    description = if e.issue == :empty
        "is empty"
    elseif e.issue == :reserved
        "is reserved"
    elseif e.issue == :separator
        "contains the separator character"
    elseif e.issue == :suffix
        "cannot end with the character"
    elseif e.issue == :char
        "contains the reserved character"
    else
        "is invalid"
    end
    print(io, "Invalid segment in $T: ")
    show(io, e.segment)
    print(io, ' ', description)
    if isnothing(e.particular)
        print(io, '.')
    else
        print(io, ' ')
        show(io, e.particular)
        print(io, '.')
    end
end
