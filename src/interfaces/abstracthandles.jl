abstract type _AbstractResolvable{H} end # Internal implementation detail

"""
    AbstractHandle{T}

Abstract supertype for *handles* to concrete resources.

An `AbstractHandle` represents an authoritative, temporal reference to a
resource, such as a file, directory, socket, or other system-managed object.
Unlike paths, handles do not describe *where* a resource is located, but instead
refer directly to the resource itself.

Handles are typically produced by resolving an [`AbstractResolvable`](@ref)
value via [`handle`](@ref). Operations that interact with the external world
(e.g. reading, writing, renaming) should prefer working with handles rather than
paths in order to avoid time-of-check/time-of-use (TOCTTOU) issues.

`AbstractHandle` subtypes may encapsulate operating system resources (such as
file descriptors) or virtual resources provided by a filesystem or service.

!!! note
    Handles are authoritative and may become invalid over time (e.g. after
    being closed). They should not be treated as stable identifiers.
"""
abstract type AbstractHandle{H} <: _AbstractResolvable{AbstractHandle{H}} end

"""
    AbstractResolvable{H <: AbstractHandle}

Abstract type for paths or handles that can be resolved to a `H`.

All non-`AbstractHandle` subtypes must implement [`handle`](@ref).
"""
const AbstractResolvable{H} = _AbstractResolvable{AbstractHandle{H}}

"""
    handle(x::AbstractResolvable{H}) :: H

Resolve `x` into a handle of type `H`.

If `x` is already an `AbstractHandle`, it is returned unmodified.
"""
function handle(h::AbstractHandle) h end
