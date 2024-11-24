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
*(a::AbstractPath{T}, b::AbstractPath{T}) -> AbstractPath{T}
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

@doc """
    basename(path::AbstractPath{T}) -> T

Return the terminal component of `path`.

!!! note
     Part of the [`AbstractPath`](@ref) interface.
""" Base.basename

Base.eltype(::Type{AbstractPath{T}}) where {T} = T

# AbstractPath API: optional methods

"""
    isabsolute(path::AbstractPath) -> Bool

Return `true` if `path` is absolute, `false` otherwise.

!!! note
     Optional component of the [`AbstractPath`](@ref) interface.
"""
isabsolute(path::AbstractPath) = !isnothing(root(path))

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
