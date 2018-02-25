__precompile__()

module ZStd

export decompress, decompress!

if isfile(joinpath(dirname(@__FILE__), "..", "deps", "deps.jl"))
    include(joinpath(dirname(@__FILE__), "..", "deps", "deps.jl"))
else
    error("ZStd.jl is not properly installed. Please run Pkg.build(\"ZStd\") " *
          "and restart Julia.")
end


struct ZStdError <: Exception
    msg::String
end

Base.showerror(io::IO, ex::ZStdError) = print(io, "ZStd: " * ex.msg)

# check whether the strides of A correspond to contiguous data
# shamelessly stolen from https://github.com/stevengj/Blosc.jl
iscontiguous(::Array) = true
iscontiguous(::Vector) = true
iscontiguous(A::DenseVector) = stride(A,1) == 1
function iscontiguous(A::DenseArray)
    p = sortperm([strides(A)...])
    s = 1
    for k = 1:ndims(A)
        if stride(A,p[k]) != s
            return false
        end
        s *= size(A,p[k])
    end
    return true
end


# Determine whether the input represents a zstd error, yes => throw it, no => return it
function check_zstd_error(code::Csize_t)
    iserr = Bool(ccall((:ZSTD_isError, libzstd), Cuint, (Csize_t, ), code))
    if iserr
        msg = unsafe_string(ccall((:ZSTD_getErrorName, libzstd), Ptr{Cchar}, (Csize_t, ), code))
        throw(ZStdError(msg))
    end
    return code # input is not an error
end


"""
    ZStd.MAX_COMPRESSION

An integer representing the maximum compression level available.
"""
const MAX_COMPRESSION = Int(ccall((:ZSTD_maxCLevel, libzstd), Cint, ()))


"""
    maxcompressedsize(srcsize)

Get the maximum compressed size in the worst-case scenario for a given input size.
"""
function maxcompressedsize(srcsize::Csize_t)
    return ccall((:ZSTD_compressBound, libzstd), Csize_t, (Csize_t, ), srcsize)
end

maxcompressedsize(srcsize::Int) = Int(maxcompressedsize(Csize_t(srcsize)))


"""
    ZStd.ZSTD_VERSION

The version of Zstandard in use.
"""
const ZSTD_VERSION = let
    ver = Int(ccall((:ZSTD_versionNumber, libzstd), Cuint, ()))
    str = join(match(r"(\d+)(\d{2})(\d{2})$", string(ver)).captures, ".")
    VersionNumber(str)
end

# Simple API
function ZSTD_compress(dst::Ptr, dstCapacity::Csize_t, src::Ptr, compressedSize::Csize_t, compressionLevel::Cint)
    return ccall((:ZSTD_decompress, libzstd), Csize_t,
      (Ptr{Void}, Csize_t, Ptr{Void}, Csize_t, Cint),
      dst, dstCapacity, src, compressedSize, compressionLevel)
end

function ZSTD_decompress(dst::Ptr, dstCapacity::Csize_t, src::Ptr, compressedSize::Csize_t)
    return ccall((:ZSTD_decompress, libzstd), Csize_t,
      (Ptr{Void}, Csize_t, Ptr{Void}, Csize_t),
      dst, dstCapacity, src, compressedSize)
end

const ZSTD_CONTENTSIZE_UNKNOWN = typemax(Culonglong)
const ZSTD_CONTENTSIZE_ERROR = typemax(Culonglong) - 1
function getFrameContentSize(src::Ptr, srcSize::Csize_t)
    return ccall((:ZSTD_getFrameContentSize, libzstd), Culonglong,
      (Ptr{Void}, Csize_t),
      src, srcSize)
end

"""
    decompress!(dst::DenseVector{T}, src::DenseVector{UInt8})
Like `decompress`, but uses a pre-allocated destination buffer `dst`,
which is resized as needed to store the decompressed data from `src`.
"""
function decompress!{T}(dst::DenseVector{T}, src::DenseVector{UInt8})
    if !iscontiguous(dst) || !iscontiguous(src)
        throw(ArgumentError("Source and Destination must be contiguous arrays"))
    end
    if !isbits(T)
        throw(ArgumentError("Destination must be a DenseVector of `isbits` element types"))
    end

    sT = sizeof(T)
    uncompressed = getFrameContentSize(pointer(src), Csize_t(sizeof(src)))
    if uncompressed == 0
        return resize!(dst, 0)
    elseif uncompressed == ZSTD_CONTENTSIZE_ERROR
        error("Error while reading frame content size.")
    elseif uncompressed == ZSTD_CONTENTSIZE_UNKNOWN
        # Should use streaming decompression
        uncompressed = sT * div(min(1000000000, 100 * sizeof(src)), sT)
        warn("Can't determine uncompressed size - setting buffer to $(div(uncompressed, 1000000)) MB")
    end
    if mod(uncompressed, sT) > 0
        error("uncompressed data is not a multiple of sizeof($T)")
    end

    elCnt = div(uncompressed, sT)
    resize!(dst, elCnt)
    uncompressed = check_zstd_error(ZSTD_decompress(pointer(dst), Csize_t(sizeof(dst)), pointer(src), Csize_t(sizeof(src))))
    return resize!(dst, uncompressed)
end

"""
    decompress(T::Type, src::DenseVector{UInt8})
Return the compressed buffer `src` as an array of element type `T`.
"""
decompress{T}(::Type{T}, src::DenseVector{UInt8}) = decompress!(Vector{T}(0), src)


end # module
