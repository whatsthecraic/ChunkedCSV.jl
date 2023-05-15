using ChunkedCSV
using Test
using Dates
using FixedPointDecimals
@testset "estimate_task_size" begin
    function _get_ctx(; last_newline_at, newlines_num, buffersize, nworkers)
        eols = zeros(Int32, newlines_num)
        eols[end] = last_newline_at
        ChunkedCSV.ParsingContext(
            1,
            DataType[],
            ChunkedCSV.Enums.CSV_TYPE[],
            Symbol[],
            zeros(UInt8, buffersize),
            ChunkedCSV.BufferedVector(eols),
            0,
            UInt8(nworkers),
            0x00,
            ChunkedCSV.TaskCounter(),
            nothing
        )
    end
    # Empty input (only 0 as end of line) -> return 1
    ctx = _get_ctx(; last_newline_at=0, newlines_num=1, buffersize=2*16*1024, nworkers=4)
    @test ChunkedCSV.estimate_task_size(ctx) == 1

    # Each row is 1 byte, submit everything in a single task
    ctx = _get_ctx(; last_newline_at=100, newlines_num=100, buffersize=100, nworkers=1)
    @test ChunkedCSV.estimate_task_size(ctx) == 100

    ctx = _get_ctx(; last_newline_at=100000, newlines_num=100000, buffersize=100000, nworkers=2)
    @test ChunkedCSV.estimate_task_size(ctx) == 50000

    ctx = _get_ctx(; last_newline_at=100000, newlines_num=100000, buffersize=100000, nworkers=3)
    @test ChunkedCSV.estimate_task_size(ctx) == 33334

    # Each task should be at least 16KiB (ChunkedCSV.MIN_TASK_SIZE_IN_BYTES) worht of data to work on
    ctx = _get_ctx(; last_newline_at=100000, newlines_num=100000, buffersize=100000, nworkers=10)
    @test ChunkedCSV.estimate_task_size(ctx) == 16*1024

    # 2 is a minimum for a non-empty input
    ctx = _get_ctx(; last_newline_at=3*16*1024, newlines_num=3, buffersize=3*16*1024, nworkers=2)
    @test ChunkedCSV.estimate_task_size(ctx) == 2

    ctx = _get_ctx(; last_newline_at=3*16*1024, newlines_num=6, buffersize=3*16*1024, nworkers=2)
    @test ChunkedCSV.estimate_task_size(ctx) == 3

    ctx = _get_ctx(; last_newline_at=3*16*1024, newlines_num=12, buffersize=3*16*1024, nworkers=2)
    @test ChunkedCSV.estimate_task_size(ctx) == 6

    ctx = _get_ctx(; last_newline_at=2*16*1024, newlines_num=12, buffersize=2*16*1024, nworkers=4)
    @test ChunkedCSV.estimate_task_size(ctx) == 6

    ctx = _get_ctx(; last_newline_at=2*16*1024, newlines_num=12, buffersize=2*16*1024, nworkers=1)
    @test ChunkedCSV.estimate_task_size(ctx) == 12
end

for alg in (:serial, :parallel)
    @testset "MmapStream ($alg)" begin
        function _iostream(x::String)
            (path, io) = mktemp()
            write(io, x)
            close(io)
            return path
        end
        testctx = ChunkedCSV.TestContext()
        parse_file(_iostream("""
            a,b,c
            1,2,3
            3,4,4
            """),
            [Int,Int,Int],
            testctx,
            _force=alg,
            buffersize=8,
            use_mmap=true,
        )
        @test testctx.header == [:a, :b, :c]
        @test testctx.schema == [Int, Int, Int]
        @test testctx.results[1].cols[1] == [1]
        @test testctx.results[1].cols[2] == [2]
        @test testctx.results[1].cols[3] == [3]
        @test testctx.results[2].cols[1] == [3]
        @test testctx.results[2].cols[2] == [4]
        @test testctx.results[2].cols[3] == [4]
        @test length(testctx.results[1].cols[1]) == 1
        @test length(testctx.results[1].cols[2]) == 1
        @test length(testctx.results[1].cols[3]) == 1
        @test length(testctx.results[2].cols[1]) == 1
        @test length(testctx.results[2].cols[2]) == 1
        @test length(testctx.results[2].cols[3]) == 1
    end
end

@testset "_is_supported_type" begin
    @test ChunkedCSV._is_supported_type(Bool)
    @test ChunkedCSV._is_supported_type(Int)
    @test ChunkedCSV._is_supported_type(Int8)
    @test ChunkedCSV._is_supported_type(Int16)
    @test ChunkedCSV._is_supported_type(Int32)
    @test ChunkedCSV._is_supported_type(Int64)
    @test ChunkedCSV._is_supported_type(UInt)
    @test ChunkedCSV._is_supported_type(UInt8)
    @test ChunkedCSV._is_supported_type(UInt16)
    @test ChunkedCSV._is_supported_type(UInt32)
    @test ChunkedCSV._is_supported_type(UInt64)
    @test ChunkedCSV._is_supported_type(Float16)
    @test ChunkedCSV._is_supported_type(Float32)
    @test ChunkedCSV._is_supported_type(Float64)
    @test ChunkedCSV._is_supported_type(String)
    @test ChunkedCSV._is_supported_type(ChunkedCSV.GuessDateTime)
    @test ChunkedCSV._is_supported_type(Date)
    @test ChunkedCSV._is_supported_type(DateTime)
    @test ChunkedCSV._is_supported_type(Time)

    @test ChunkedCSV._is_supported_type(FixedDecimal{Int,8})
    @test ChunkedCSV._is_supported_type(FixedDecimal{UInt128,16})
    @test ChunkedCSV._is_supported_type(FixedDecimal{UInt8,0})
    @test ChunkedCSV._is_supported_type(FixedDecimal{UInt8,1})
    @test ChunkedCSV._is_supported_type(FixedDecimal{UInt8,2})
    @test !ChunkedCSV._is_supported_type(FixedDecimal{UInt8,3})
    @test !ChunkedCSV._is_supported_type(FixedDecimal{UInt128,100})

    @test !ChunkedCSV._is_supported_type(ComplexF16)
    @test !ChunkedCSV._is_supported_type(ComplexF32)
end

@testset "_isemptyrow" begin
    @test ChunkedCSV._isemptyrow(0, 1, UInt8[])
    @test ChunkedCSV._isemptyrow(1, 2, UInt8[])
    @test !ChunkedCSV._isemptyrow(1, 4, UInt8[])
    @test ChunkedCSV._isemptyrow(1, 3, UInt8['\n', '\r', '\n'])
    @test !ChunkedCSV._isemptyrow(1, 3, UInt8['\n', 'a', '\n'])
end
