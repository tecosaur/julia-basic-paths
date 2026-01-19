"""
    AbstractPath{T, L}

Abstract type for *paths*, defined by a series of segments of type `T` that
describe a location of type `L`.

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
abstract type AbstractPath{T, L} <: AbstractResolvable{L} end

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

Base.eltype(::Type{<:AbstractPath{T}}) where {T} = T

# AbstractPath API: optional methods

"""
    isabsolute(path::AbstractPath) -> Bool

Return `true` if `path` is absolute, `false` otherwise.

!!! note
     Optional component of the [`AbstractPath`](@ref) interface.
"""
isabsolute(path::AbstractPath) = !isnothing(root(path))
