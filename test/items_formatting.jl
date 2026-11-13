using TestItemRunner

@testitem "millisecond duration formatting agrees across units and boundaries" setup=[TreebarsTestImports] tags=[:unit, :render, :format] begin
    for ms in (-60_001, -1, 0, 1, 99, 100, 999, 1000, 1234, 59_999,
               60_000, 60_001, 3_600_000, 86_400_001, 604_800_000)
        d = Millisecond(ms)
        parts = Dates.CompoundPeriod(d)
        @test short_duration(d) == short_duration(parts)
        for t in (treebar_texts(:en), treebar_texts(:de))
            @test Treebars._duration_text(d, t) == Treebars._duration_text(parts, t)
        end
    end
    @test short_duration(Second(61)) == "1m 1s"
    @test short_duration(Hour(1) + Minute(2) + Second(3)) == "1h 2m"
end
