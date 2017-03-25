__precompile__()
"""
Simple String Table and load/save functions

Author:     Scott Paul Jones
Copyright:  2017 Gandalf Software, Inc (and any future contributors)
License:    MIT (see https://github.com/JuliaString/StrTables.jl/blob/master/LICENSE.md)

## Public API:

# Exported:
* StrTable takes a Vector of some `AbstractString` type
  and returns a compact string table, that acts as a `AbstractVector{String}`

# Not exported:
* matchfirst takes a sorted string table and a string,
  returns a vector of elements that start with the string
* matchfirstrng takes a sorted string table and a string,
  returns the range of indexes of elements start with the string
* save takes a filename and a collection (of simple types) and
  saves them to the file in a simple format
* load takes a filename and returns a Vector of the values stored by save in the file
"""
module StrTables
export StrTable, PackedTable, AbstractPackedTable, AbstractEntityTable

eval(Expr(:abstract, :(AbstractPackedTable{T} <: AbstractVector{T})))

"""
Compact table
Designed to save memory compared to a `Vector{Vector{S}}`
Allows for fast lookup of ranges when input was sorted
Can be saved/loaded to/from a file quickly
"""
immutable PackedTable{T,S,O} <: AbstractPackedTable{T}
    offsetvec::Vector{O}
    namtab::Vector{S}
end

PackedTable{T,S,O}(::Type{T}, offvec::Vector{O}, namtab::Vector{S}) =
    PackedTable{T,S,O}(offvec, namtab)

eval(Expr(:abstract, :(AbstractEntityTable <: AbstractVector{String})))
"""
Abstract type for Entity tables:
Supports lookupname, matchchar, matches, longestmatches, completions
"""
AbstractEntityTable

_getsize(el::String) = sizeof(el)
_getsize{T}(el::Vector{T}) = length(el)

function pack_table{T,S}(::Type{T}, ::Type{S}, strvec)
    namvec = Vector{S}()
    offvec = Vector{UInt32}(length(strvec)+1)
    offvec[1] = 0%UInt32
    offset = 0%UInt32
    for (i,str) in enumerate(strvec)
        offset += _getsize(str)
        offvec[i+1] = offset
        append!(namvec, Vector{S}(str))
    end
    (offset > 0x0ffff
     ? PackedTable{T,S,UInt32}(offvec, namvec)
     : PackedTable{T,S,UInt16}(copy!(Vector{UInt16}(length(strvec)+1), offvec), namvec))
end

"""Make a single table of a vector of elements of type T"""
PackedTable{T}(strvec::Vector{T}) = pack_table(T, isa(T, String) ? UInt8 : eltype(T), strvec)

eval(Expr(:typealias, :(StrTable{T}), :(PackedTable{T,UInt8})))
"""
Compact string table
Designed to save memory compared to a `Vector{String}`
Allows for fast lookup of ranges when input was sorted
Can be saved/loaded to/from a file quickly
"""
StrTable
StrTable{T<:AbstractString}(strvec::Vector{T}) = pack_table(String, UInt8, strvec)

Base.getindex{T}(str::AbstractPackedTable{T}, ind::Integer) =
    T(str.namtab[str.offsetvec[ind]+1:str.offsetvec[ind+1]])
Base.size(str::AbstractPackedTable) = (length(str.offsetvec)-1,)
@static if VERSION < v"0.6.0-dev.2840"
    Base.linearindexing{T<:AbstractPackedTable}(::Type{T}) = Base.LinearFast()
else
    Base.IndexStyle{T<:AbstractPackedTable}(::Type{T}) = Base.LinearFast()
end
Base.start(str::AbstractPackedTable) = 1
Base.next(str::AbstractPackedTable, state) = (getindex(str, state), state+1)
Base.done(str::AbstractPackedTable, state) = state == length(str.offsetvec)

# Get all indices that start with a string

_memcmp(v1, v2, l) = ccall(:memcmp, Int32, (Ptr{UInt8}, Ptr{UInt8}, UInt), v1, v2, l)
_veccmp(l1, l2, v1, v2) = _memcmp(v1, v2, min(l1, l2))

@inline function _lexcmp(l1, l2, v1, v2)
    c = _veccmp(l1, l2, v1, v2)
    c < 0 ? -1 : c > 0 ? +1 : cmp(l1, l2)
end

_ltvec(v1, v2) = _lexcmp(sizeof(v1), sizeof(v2), v1, v2) < 0

"""Return the range of indices of values that whose beginning matches the string"""
matchfirstrng(tab::AbstractPackedTable, str::AbstractString) = matchfirstrng(tab, String(str))
matchfirstrng(tab::AbstractPackedTable, str::String) = matchfirstrng(tab, Vector{UInt8}(str))
function matchfirstrng{T}(tab::AbstractPackedTable, str::Vector{T})
    pos = searchsortedfirst(tab, str, lt=_ltvec)
    len = length(tab)
    pos > len && return pos:pos-1
    beg = pos
    l1 = sizeof(str)
    prevoff = tab.offsetvec[pos]
    while pos <= len
        curoff = tab.offsetvec[pos+1]
        l1 > curoff - prevoff && break
        _memcmp(str, pointer(tab.namtab, prevoff+1), l1) != 0 && break
        prevoff = curoff
        pos += 1
    end
    beg:pos-1
end

"""Return a vector of values that whose beginning matches the string"""
matchfirst(tab::AbstractPackedTable, str) = tab[matchfirstrng(tab, str)]
    
"""Given an entity name, return the string it represents, or an empty string if not found"""
function lookupname end

"""Given a character, return all exact matches to the character as a vector"""
function matchchar end

"""Given a string, return all exact matches to the string as a vector"""
function matches end

"""Given a string, return all of the longest matches to the beginning of the string as a vector"""
function longestmatches end

"""Given a string, return all of the entity names that start with that string, if any"""
function completions end

# Support for saving and loading

# This use a simple format to store single Unsigned values (UInt8-UInt64),
# Vectors of Unsigned values, and StrTable values

const VECTOR_CODE = 0x0
const STRTAB_CODE = 0x1
const PACKED_CODE = 0x2
const STRING1_CODE = 0x3
const STRING2_CODE = 0x4
const STRING4_CODE = 0x5
const BASE_CODE = 0x5

const type_tab = (UInt8, UInt16, UInt32, UInt64, UInt128,
                  Int8, Int16, Int32, Int64, Int128,
                  Float16, Float32, Float64)
const SupTypes = Union{type_tab...}

for (i, typ) in enumerate(type_tab)
    @eval _get_code(::Type{$typ})  = $((i+BASE_CODE)%UInt8)
end

const MAX_CODE = (length(type_tab)+BASE_CODE)%UInt8

const VER = 0x00000001

write_value{T<:SupTypes}(io::IO, val::T) = write(io, _get_code(T), val)

write_value{T<:AbstractString}(io::IO, val::T) = write_value(io, String(val))
function write_value(io::IO, str::String)
    siz = sizeof(str)
    if siz < 256
        write(io, STRING1_CODE, sizeof(str)%UInt8, str)
    elseif siz < 65536
        write(io, STRING2_CODE, sizeof(str)%UInt16, str)
    elseif siz <= 0xffffffff
        write(io, STRING4_CODE, sizeof(str)%UInt32, str)
    else
        error("String too large: $siz")
    end
end

write_value{T<:SupTypes}(io::IO, val::Vector{T}) =
    (write(io, _get_code(T) | 0x80, length(val)%UInt32, val))

function write_value{T,S,O}(io::IO, tab::PackedTable{T,S,O})
    write(io, (T == String && S == UInt8) ? STRTAB_CODE : PACKED_CODE)
    write_value(io, tab.offsetvec)
    write_value(io, tab.namtab)
end

"""Save a collection of values (StrTable, String, Float*, UInt*, Int*) into an IO object"""
function save(io::IO, values)
    write(io, VER)
    for val in values
        write_value(io, val)
    end
end

"""Save a collection of values (StrTable, String, Float*, UInt*, Int*) into a file"""
function save(filename::AbstractString, values)
    open(filename, "w") do io
        save(io, values)
    end
end

"""Read a single StrTable, String, UInt, or Vector of UInt value from the io device"""
function read_value(io::IO)
    typ = read(io, UInt8)
    # Check for vector
    if (BASE_CODE|0x80) < typ <= (MAX_CODE|0x80)
        len = read(io, UInt32)
        res = read(io, type_tab[typ-0x80-BASE_CODE], len)
    elseif typ == STRTAB_CODE
        off = read_value(io)
        nam = read_value(io)
        res = PackedTable(String, off, nam)
    elseif typ == PACKED_CODE
        off = read_value(io)
        nam = read_value(io)
        res = PackedTable(typeof(nam), off, nam)
    elseif typ == STRING1_CODE
        len = read(io, UInt8)
        res = String(read(io, len))
    elseif typ == STRING2_CODE
        len = read(io, UInt16)
        res = String(read(io, len))
    elseif typ == STRING4_CODE
        len = read(io, UInt32)
        res = String(read(io, len))
    elseif typ <= MAX_CODE
        res = read(io, type_tab[typ-BASE_CODE])
    else
        error("Unsupported type code $typ")
    end
end

"""Return a Vector{Any} with data tables loaded from IO"""
function load(io::IO)
    res = Vector{Any}()
    ver = read(io, UInt32)
    ver != VER && error("File version $ver doesn't match current version $VER")
    while !eof(io)
        push!(res, read_value(io))
    end
    res
end

"""Return a Vector{Any} with data tables loaded from file"""
function load(filename::AbstractString)
    open(filename) do io
        load(io)
    end
end

end # module
