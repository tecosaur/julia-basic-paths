# Implementation of the `GenericPlainPathBuf` type and its methods.

# This is an optional complement to the `GenericPlainPath`
# type that allows for efficient mutation using a path buffer.

struct GenericPlainPathBuf{P <: PlainPath} <: PlainPath
    data::Vector{UInt8}
    # I don't think this is actually necessary - but I may be repeating myself.
    # It'll just double the amount of allocations, when the separators can quickly
    # be found in the data itself.
    separators::Vector{UInt16}
end

function root(path::GenericPlainPathBuf{P}) where {P <: PlainPath}
    isempty(path.separators) && return nothing
    rootlen = first(path.separators)
    rootlen == 0 && return nothing
    rootdata = path.data[1:rootlen+1]
    # This is interesting. What's the purpose of appending a 0x00 byte here?
    # For C operability? Maybe that makes sense.
    rootdata[end] = 0x00
    GenericPlainPathBuf{P}(rootdata, [rootlen])
end

isabsolute(path::GenericPlainPathBuf) =
    !isempty(path.separators) && !iszero(first(path.separators))

function parent(path::GenericPlainPathBuf{P}) where {P <: PlainPath}
    isempty(path.separators) && return nothing
    parentdata = path.data[1:last(path.separators)]
    parentdata[end] = 0x00
    GenericPlainPathBuf{P}(parentdata, path.separators[1:end-1])
end

function basename(path::GenericPlainPathBuf{P}) where {P <: PlainPath}
    if isempty(path.separators) ||iszero(first(path.separators))
        SubString(String(copy(path.data)))
    else
        SubString(String(path.data[last(path.separators)+1:end-1]))
    end
end

function Base.iterate(path::GenericPlainPathBuf{P}, index::Int=1) where {P}
    index > length(path) && return nothing
    if isempty(path.separators)
        return if index == 1 String(copy(path.data)), 2 end
    end
    path[index], index + 1
end

function segment_range(path::GenericPlainPathBuf, index::Int)
    isempty(path.separators) && return 1:(length(path.data) - 1)
    start = if index == 1 && !isone(first(path.separators))
        1
    else
        path.separators[index] + 1
    end
    stop = if index < length(path)
        path.separators[index + 1] - 1
    else
        length(path.data) - 1
    end
    start:stop
end

function Base.getindex(path::GenericPlainPathBuf{P}, index::Int) where {P}
    @boundscheck checkbounds(path, index)
    isempty(path.separators) && return String(copy(path.data))
    SubString(String(path.data[segment_range(path, index)]))
end

Base.length(path::GenericPlainPathBuf) = length(path.separators) + isempty(path.separators)

function Base.:(*)(a::GenericPlainPathBuf{P}, b::GenericPlainPathBuf{P}) where {P}
    isabsolute(b) && return b
    cdata = Vector{UInt8}(undef, length(a.data) + length(b.data) + 1)
    copyto!(cdata, a.data)
    cdata[length(a.data) + 1] = separatorbyte(P)
    copyto!(cdata, length(a.data) + 2, b.data)
    csegments = Vector{UInt16}(undef, length(a.separators) + length(b.separators) + 1)
    copyto!(csegments, a.separators)
    csegments[length(a.separators) + 1] = length(a.data) + 1
    copyto!(csegments, length(a.separators) + 2, b.separators .+ (length(a.data) + 1))
    GenericPlainPathBuf{P}(cdata, csegments)
end

separator(::Type{GenericPlainPathBuf{P}}) where {P <: PlainPath} = separator(P)

Base.string(path::GenericPlainPathBuf) = String(path.data[1:end-1])

# Path buffer specific methods

function Base.push!(path::GenericPlainPathBuf{P}, segment::AbstractString) where {P}
    if segment == selfsegment(P)
        # Normally, `push!` returns the first argument.
        return
    # This is not correct: If `b` is a symlink, then `/a/b/..` is not `/a`.
    # See e.g. https://doc.rust-lang.org/src/std/path.rs.html#2763
    elseif segment == parentsegment(P)
        pop!(path)
        return
    end
    push!(path.separators, UInt16(length(path.data)))
    path.data[end] = separatorbyte(P)
    append!(path.data, codeunits(segment))
    push!(path.data, 0x00)
    nothing
end

function Base.pop!(path::GenericPlainPathBuf)
    isempty(path.separators) && throw(ArgumentError("Path must be non-empty"))
    lastseg = pop!(path.separators)
    segment = SubString(String(path.data[lastseg+1:end-1]))
    resize!(path.data, lastseg + isone(lastseg))
    path.data[end] = 0x00
    segment
end

function Base.popfirst!(path::GenericPlainPathBuf)
    isempty(path.separators) && throw(ArgumentError("Path must be non-empty"))
    !iszero(first(path.separators)) && throw(ArgumentError("Path must be relative"))
    nextsep = if length(path.separators) == 1
        length(path.data)
    else
        path.separators[2]
    end
    segment = SubString(String(path.data[1:nextsep-!isone(first(path.separators))]))
    deleteat!(path.data, 1:nextsep)
    popfirst!(path.separators)
    for i in eachindex(path.separators)
        path.separators[i] -= nextsep
    end
    segment
end

function Base.setindex!(path::GenericPlainPathBuf, segment::String, index::Int)
    @boundscheck checkbounds(path, index)
    oldseg = segment_range(path, index)
    oldlen = length(oldseg)
    newlen = ncodeunits(segment)
    if newlen != oldlen
        shift = newlen - oldlen
        initiallen = length(path.data)
        resize!(path.data, length(path.data) + shift)
        Libc.memmove(pointer(path.data, last(oldseg) + shift), pointer(path.data, last(oldseg)), initiallen - last(oldseg))
        for (i, seg) in enumerate(path.separators) # TODO: calculate appropriate range of segments to update
            if seg > last(oldseg)
                path.separators[i] += shift
            end
        end
    end
    copyto!(path.data, first(oldseg), codeunits(segment))
    path
end

Base.setindex!(path::GenericPlainPathBuf, segment::AbstractString, index::Int) =
    setindex!(path, String(segment), index)

# Conversion

function Base.convert(::Type{GenericPlainPathBuf{P}}, path::GenericPlainPath{P}) where {P <: PlainPath}
    separators = UInt16[]
    if iszero(path.rootsep)
        push!(separators, path.rootsep)
    end
    append!(separators, findall(==(separatorbyte(P)), codeunits(path.data)))
    data = collect(codeunits(path.data))
    push!(data, 0x00)
    GenericPlainPathBuf{P}(data, separators)
end

function Base.convert(::Type{GenericPlainPath{P}}, path::GenericPlainPathBuf{P}) where {P <: PlainPath}
    rootsep, lastsep = if isempty(path.separators)
        zero(UInt16), zero(UInt16)
    elseif length(path.separators) == 1 && iszero(first(path.separators))
        zero(UInt16), first(path.separators)
    else
        first(path.separators), last(path.separators)
    end
    GenericPlainPath{P}(string(path), rootsep, lastsep, 0)
end

# These methods need to be implemented here for
# `GenericPlainPath` and `GenericPlainPathBuf`.

function generic_rewrap(f::F, path::PlainPath) where {F <: Function}
    gp = genericpath(path)
    P = if gp isa GenericPlainPath
        (((::GenericPlainPath{P}) where {P}) -> P)(gp)
    elseif gp isa GenericPlainPathBuf
        (((::GenericPlainPathBuf{P}) where {P}) -> P)(gp)
    else
        throw(ArgumentError("Unsupported path type: $(typeof(path))"))
    end
    P(f(gp))
end

function Base.:(*)(a::PlainPath, b::PlainPath)
    cgp = genericpath(a) * genericpath(b)
    P = if cgp isa GenericPlainPath
        (((::GenericPlainPath{P}) where {P}) -> P)(cgp)
    elseif cgp isa GenericPlainPathBuf
        (((::GenericPlainPathBuf{P}) where {P}) -> P)(cgp)
    else
        throw(ArgumentError("Unsupported path type: $(typeof(cgp))"))
    end
    P(cgp)
end
