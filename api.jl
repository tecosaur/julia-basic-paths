"""
    AbstractPath{T}

Abstract type for *paths*, defined by a series of segments of type `T` that
describe a location.

This can be thought of as an analogue of `Vector{T}`, with extra semantics, an
in fact can be iterated over and `collect`ed into a `Vector{T}` .

# Interface

```
root(path::AbstractPath{T}) -> Union{AbstractPath{T}, Nothing}
parent(path::AbstractPath{T}) -> Union{AbstractPath{T}, Nothing}
basename(path::AbstractPath{T}) -> T
length(path::AbstractPath{T}) -> Int
iterate(path::AbstractPath{T}) -> T...
*(a::AbstractPath{T}, b::AbstractPath{T}) -> AbstractPath{T}
```

Optional methods, with generic implementations derived
from the base interface:

```
isabsolute(path::AbstractPath{T}) -> Bool
getindex(path::AbstractPath{T}, i::Int) -> T
firstindex(path::AbstractPath{T}) -> Int
lastindex(path::AbstractPath{T}) -> Int
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

"""
    parent(path::AbstractPath{T}) -> Union{AbstractPath{T}, Nothing}

Return the immediate parent of `path`, if it exists.

!!! note
     Part of the [`AbstractPath`](@ref) interface.
"""
function parent end

"""
    basename(path::AbstractPath{T}) -> T

Return the terminal component of `path`.

!!! note
     Part of the [`AbstractPath`](@ref) interface.
"""
function basename end

# AbstractPath API: optional methods

"""
    isabsolute(path::AbstractPath) -> Bool

Return `true` if `path` is absolute, `false` otherwise.

!!! note
     Optional component of the [`AbstractPath`](@ref) interface.
"""
isabsolute(path::AbstractPath) = !isnothing(root(path))

Base.firstindex(::AbstractPath) = 1
Base.lastindex(path::AbstractPath) = length(path)

function Base.getindex(path::AbstractPath, i::Int)
    i < firstindex(path) && throw(BoundsError(i))
    val, itr = iterate(path)
    while (i -= 1) > 0
        next = iterate(path, itr)
        isnothing(next) && throw(BoundsError(i))
    end
    val
end

Base.checkbounds(::Type{Bool}, ap::AbstractPath, i::Int) =
    firstindex(ap) <= i <= lastindex(ap)

Base.checkbounds(ap::AbstractPath, i::Int) =
    if !checkbounds(Bool, ap, i) throw(BoundsError(ap, i)) end

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
string(path::PlainPath) -> String
```

You can skip implementing the `string` method if you implement
the generic backed methods:

```
genericpath(path::PlainPath) -> GenericPlainPath | GenexicPlainPathBuf
T(path::GenericPlainPath{T}) -> T
T(path::GenericPlainPathBuf{T}) -> T
```

By implementing these methods, the [`AbstractPath`](@ref) iterface is also
implemented by fallback `PlainPath` methods that assume generic backing.
Otherwise, you must implement the `AbstractPath` interface.

Optionally, a `PlainPath` can be extended with the concept of self and parent
reference segments:
```
selfsegment(::Type{<:PlainPath}) -> String
parentsegment(::Type{<:PlainPath}) -> String
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
