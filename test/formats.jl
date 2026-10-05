@testset "Exact IEEE encodings and rounding" begin
    @test_throws ArgumentError FloatFormat(1, 23)
    @test_throws ArgumentError FloatFormat(11, 53)
    @test_throws ArgumentError FixedFormat(16, 17)
    @test FixedFormat(16, 4).integer_bits == 4
    @test_throws ArgumentError decode_ieee(0x10000, IEEE16)
    @test_throws ArgumentError round_ieee(1, IEEE32; mode = :unknown)
    @test decode_ieee(0x80000000, IEEE32).negative
    @test decode_ieee(0x80000000, IEEE32).kind == :zero
    @test decode_ieee(0x00000001, IEEE32).value == BigInt(1) // (BigInt(1) << 149)
    @test decode_ieee(0x3f800000, IEEE32).value == 1
    @test round_ieee(1 // 3, IEEE32) == 0x3eaaaaab
    @test round_ieee(1 // 10, IEEE64) == 0x3fb999999999999a
    # Independent host decoding, then exact encoder round trip for every half bit pattern.
    for bits = UInt16(0):typemax(UInt16)
        x = reinterpret(Float16, bits)
        d = decode_ieee(bits, IEEE16)
        if isfinite(x)
            @test d.value == Rational{BigInt}(x)
            @test round_ieee(d.value, IEEE16; zero_sign = signbit(x)) == bits
        else
            @test d.kind == (isnan(x) ? :nan : :infinity)
        end
    end
    for f in (IEEE16, IEEE32, IEEE64, FloatFormat(3, 4))
        M = f.fraction_bits
        emin = 1 - ((1 << (f.exponent_bits - 1)) - 1)
        quantum = emin - M
        halfsub = BigInt(1) // (BigInt(1) << (1 - quantum))
        sign = UInt64(1) << (f.exponent_bits + M)
        one = PRESAGe._bias(f) << M
        midpoint = 1 + BigInt(1) // (BigInt(1) << (M + 1))
        @test round_ieee(midpoint, f) == one
        @test round_ieee(1 + 3BigInt(1) // (BigInt(1) << (M + 1)), f) == one + 2
        @test round_ieee(-midpoint, f) == sign | one
        @test round_ieee(halfsub, f) == 0
        @test round_ieee(3halfsub, f) == 2
        @test round_ieee(-halfsub, f) == sign
        @test round_ieee(halfsub, f; mode = :up) == 1
        @test round_ieee(-halfsub, f; mode = :down) == sign | 1
        @test round_ieee(-halfsub, f; mode = :up) == sign
        @test round_ieee(midpoint, f; mode = :toward_zero) == one
        minnormal = UInt64(1) << M
        a, b = decode_ieee(minnormal - 1, f).value, decode_ieee(minnormal, f).value
        @test round_ieee((a + b) / 2, f) == minnormal
        # Overflow midpoint: hypothetical next binade wins the even tie.
        maxbits = PRESAGe._inf(f) - 1
        maxvalue = decode_ieee(maxbits, f).value
        ulp = PRESAGe._pow2(PRESAGe._emax(f) - M)
        @test round_ieee(maxvalue + ulp / 2, f) == PRESAGe._inf(f)
        @test round_ieee(maxvalue + ulp / 4, f) == maxbits
        @test round_ieee(maxvalue + ulp, f; mode = :toward_zero) == maxbits
        @test round_dyadic(1, 1_000_000_000, f) == PRESAGe._inf(f)
        @test round_dyadic(1, -1_000_000_000, f) == 0
        @test round_dyadic(-1, -1_000_000_000, f; mode = :down) == sign | 1
    end
    # All neighbour midpoints in a small format, including signed ties.
    f = FloatFormat(3, 4)
    for bits = UInt64(0):(PRESAGe._inf(f) - 2)
        a, b = decode_ieee(bits, f).value, decode_ieee(bits + 1, f).value
        expected = iseven(bits) ? bits : bits + 1
        @test round_ieee((a + b) / 2, f) == expected
        @test round_ieee(-(a + b) / 2, f) == PRESAGe._sign(f) | expected
    end
end
