/*
 * Copyright (C) 2025-2026 Gerrit Pape (gerrit.pape@uni-paderborn.de)
 *
 * This file is part of PRESAGe.
 *
 * PRESAGe is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * PRESAGe is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with PRESAGe. If not, see <https://www.gnu.org/licenses/>.
 */
#ifndef ERF_H_
#define ERF_H_

#include <math.h>
// #define M_PI 3.14159265358979323846264338327 // already defined in math.h
/*
#include <CL/sycl.hpp>
#include "dpc_common.hpp"

using namespace cl::sycl;
#if FPGA || FPGA_EMULATOR
  #include <sycl/ext/intel/fpga_extensions.hpp>
//  #include <sycl/ext/intel/ac_types/ac_int.hpp>
//  #include <sycl/ext/intel/ac_types/ap_float.hpp>
//  #include <sycl/ext/intel/ac_types/ap_float_math.hpp>
#endif
*/

namespace hls {
static const double tiny = 1e-300,
HALF_SUN= 5.00000000000000000000e-01, /* 0x3FE00000, 0x00000000 */
one = 1.00000000000000000000e+00, /* 0x3FF00000, 0x00000000 */
two = 2.00000000000000000000e+00, /* 0x40000000, 0x00000000 */
/* c = (float)0.84506291151 */
erx = 8.45062911510467529297e-01, /* 0x3FEB0AC1, 0x60000000 */
/*
* Coefficients for approximation to erf on [0,0.84375]
*/
efx = 1.28379167095512586316e-01, /* 0x3FC06EBA, 0x8214DB69 */
efx8= 1.02703333676410069053e+00, /* 0x3FF06EBA, 0x8214DB69 */
pp0 = 1.28379167095512558561e-01, /* 0x3FC06EBA, 0x8214DB68 */
pp1 = -3.25042107247001499370e-01, /* 0xBFD4CD7D, 0x691CB913 */
pp2 = -2.84817495755985104766e-02, /* 0xBF9D2A51, 0xDBD7194F */
pp3 = -5.77027029648944159157e-03, /* 0xBF77A291, 0x236668E4 */
pp4 = -2.37630166566501626084e-05, /* 0xBEF8EAD6, 0x120016AC */
qq1 = 3.97917223959155352819e-01, /* 0x3FD97779, 0xCDDADC09 */
qq2 = 6.50222499887672944485e-02, /* 0x3FB0A54C, 0x5536CEBA */
qq3 = 5.08130628187576562776e-03, /* 0x3F74D022, 0xC4D36B0F */
qq4 = 1.32494738004321644526e-04, /* 0x3F215DC9, 0x221C1A10 */
qq5 = -3.96022827877536812320e-06, /* 0xBED09C43, 0x42A26120 */
/*
* Coefficients for approximation to erf in [0.84375,1.25]
*/
pa0 = -2.36211856075265944077e-03, /* 0xBF6359B8, 0xBEF77538 */
pa1 = 4.14856118683748331666e-01, /* 0x3FDA8D00, 0xAD92B34D */
pa2 = -3.72207876035701323847e-01, /* 0xBFD7D240, 0xFBB8C3F1 */
pa3 = 3.18346619901161753674e-01, /* 0x3FD45FCA, 0x805120E4 */
pa4 = -1.10894694282396677476e-01, /* 0xBFBC6398, 0x3D3E28EC */
pa5 = 3.54783043256182359371e-02, /* 0x3FA22A36, 0x599795EB */
pa6 = -2.16637559486879084300e-03, /* 0xBF61BF38, 0x0A96073F */
qa1 = 1.06420880400844228286e-01, /* 0x3FBB3E66, 0x18EEE323 */
qa2 = 5.40397917702171048937e-01, /* 0x3FE14AF0, 0x92EB6F33 */
qa3 = 7.18286544141962662868e-02, /* 0x3FB2635C, 0xD99FE9A7 */
qa4 = 1.26171219808761642112e-01, /* 0x3FC02660, 0xE763351F */
qa5 = 1.36370839120290507362e-02, /* 0x3F8BEDC2, 0x6B51DD1C */
qa6 = 1.19844998467991074170e-02, /* 0x3F888B54, 0x5735151D */
/*
* Coefficients for approximation to erfc in [1.25,1/0.35]
*/
ra0 = -9.86494403484714822705e-03, /* 0xBF843412, 0x600D6435 */
ra1 = -6.93858572707181764372e-01, /* 0xBFE63416, 0xE4BA7360 */
ra2 = -1.05586262253232909814e+01, /* 0xC0251E04, 0x41B0E726 */
ra3 = -6.23753324503260060396e+01, /* 0xC04F300A, 0xE4CBA38D */
ra4 = -1.62396669462573470355e+02, /* 0xC0644CB1, 0x84282266 */
ra5 = -1.84605092906711035994e+02, /* 0xC067135C, 0xEBCCABB2 */
ra6 = -8.12874355063065934246e+01, /* 0xC0545265, 0x57E4D2F2 */
ra7 = -9.81432934416914548592e+00, /* 0xC023A0EF, 0xC69AC25C */
sa1 = 1.96512716674392571292e+01, /* 0x4033A6B9, 0xBD707687 */
sa2 = 1.37657754143519042600e+02, /* 0x4061350C, 0x526AE721 */
sa3 = 4.34565877475229228821e+02, /* 0x407B290D, 0xD58A1A71 */
sa4 = 6.45387271733267880336e+02, /* 0x40842B19, 0x21EC2868 */
sa5 = 4.29008140027567833386e+02, /* 0x407AD021, 0x57700314 */
sa6 = 1.08635005541779435134e+02, /* 0x405B28A3, 0xEE48AE2C */
sa7 = 6.57024977031928170135e+00, /* 0x401A47EF, 0x8E484A93 */
sa8 = -6.04244152148580987438e-02, /* 0xBFAEEFF2, 0xEE749A62 */
/*
* Coefficients for approximation to erfc in [1/.35,28]
*/
rb0 = -9.86494292470009928597e-03, /* 0xBF843412, 0x39E86F4A */
rb1 = -7.99283237680523006574e-01, /* 0xBFE993BA, 0x70C285DE */
rb2 = -1.77579549177547519889e+01, /* 0xC031C209, 0x555F995A */
rb3 = -1.60636384855821916062e+02, /* 0xC064145D, 0x43C5ED98 */
rb4 = -6.37566443368389627722e+02, /* 0xC083EC88, 0x1375F228 */
rb5 = -1.02509513161107724954e+03, /* 0xC0900461, 0x6A2E5992 */
rb6 = -4.83519191608651397019e+02, /* 0xC07E384E, 0x9BDC383F */
sb1 = 3.03380607434824582924e+01, /* 0x403E568B, 0x261D5190 */
sb2 = 3.25792512996573918826e+02, /* 0x40745CAE, 0x221B9F0A */
sb3 = 1.53672958608443695994e+03, /* 0x409802EB, 0x189D5118 */
sb4 = 3.19985821950859553908e+03, /* 0x40A8FFB7, 0x688C246A */
sb5 = 2.55305040643316442583e+03, /* 0x40A3F219, 0xCEDF3BE6 */
sb6 = 4.74528541206955367215e+02, /* 0x407DA874, 0xE79FE763 */
sb7 = -2.24409524465858183362e+01; /* 0xC03670E2, 0x42712D62 */

using Real = double;
static inline double sun_erf(double x)
{
    int n0,hx,ix,i;
    //double R,S,P,Q,s,y,z,r;
    n0 = ((*(int*)&one)>>29)^1;
    hx = *(n0+(int*)&x);
    ix = hx&0x7fffffff;
    Real x2 = x*x;
    Real one_by_x = one/x;
    // shared division with last interval
    if(ix>=0x7ff00000) { /* erf(nan)=nan */
        i = ((unsigned)hx>>31)<<1;
        return (Real)(1-i)+one_by_x; /* erf(+-inf)=+-1 */
    }
    // cheap pre-calculated-
    if (ix >= 0x40180000) { /* inf>|x|>=6 */
        //TODO: fix this error: undefined reference to 'llvm.copysign.f64'
        //if(hx>=0) return one-tiny; else return tiny-one;
    }
    if(ix < 0x3e300000) { /* |x|<2**-28 */
        if (ix < 0x00800000) return 0.125*(8.0*x+efx8*x); /*avoid underflow */
        return x + efx*x;
    }

    Real base;
    Real coeffsFirst[8], coeffsSecond[9];
    if(ix < 0x3feb0000) { /* |x|<0.84375 */
        base = x2;
        coeffsFirst[0] = pp0;
        coeffsFirst[1] = pp1;
        coeffsFirst[2] = pp2;
        coeffsFirst[3] = pp3;
        coeffsFirst[4] = pp4;
        coeffsFirst[5] = coeffsFirst[6] = coeffsFirst[7] =  0.0;
        coeffsSecond[1] = qq1;
        coeffsSecond[2] = qq2;
        coeffsSecond[3] = qq3;
        coeffsSecond[4] = qq4;
        coeffsSecond[5] = qq5;
        coeffsSecond[6] = coeffsSecond[7] = coeffsSecond[8] = 0.0;
    }
    else if(ix < 0x3ff40000) { /* 0.84375 <= |x| < 1.25 */
        base = fabs(x)-one;
        coeffsFirst[0] = pa0;
        coeffsFirst[1] = pa1;
        coeffsFirst[2] = pa2;
        coeffsFirst[3] = pa3;
        coeffsFirst[4] = pa4;
        coeffsFirst[5] = pa5;
        coeffsFirst[6] = pa6;
        coeffsFirst[7] =  0.0;
        coeffsSecond[1] = qa1;
        coeffsSecond[2] = qa2;
        coeffsSecond[3] = qa3;
        coeffsSecond[4] = qa4;
        coeffsSecond[5] = qa5;
        coeffsSecond[6] = qa6;
        coeffsSecond[7] = coeffsSecond[8] = 0.0;
    }
    else {
        //Real xabs = fabs(x);
        // replace division with multiplication
        //base = one/x2;
        base = one_by_x*one_by_x;
        if(ix< 0x4006DB6E) { /* |x| < 1/0.35 */
            coeffsFirst[0] = ra0;
            coeffsFirst[1] = ra1;
            coeffsFirst[2] = ra2;
            coeffsFirst[3] = ra3;
            coeffsFirst[4] = ra4;
            coeffsFirst[5] = ra5;
            coeffsFirst[6] = ra6;
            coeffsFirst[7] = ra7;
            coeffsSecond[1] = sa1;
            coeffsSecond[2] = sa2;
            coeffsSecond[3] = sa3;
            coeffsSecond[4] = sa4;
            coeffsSecond[5] = sa5;
            coeffsSecond[6] = sa6;
            coeffsSecond[7] = sa7;
            coeffsSecond[8] = sa8;
        } else { /* |x| >= 1/0.35 */
            coeffsFirst[0] = rb0;
            coeffsFirst[1] = rb1;
            coeffsFirst[2] = rb2;
            coeffsFirst[3] = rb3;
            coeffsFirst[4] = rb4;
            coeffsFirst[5] = rb5;
            coeffsFirst[6] = rb6;
            coeffsFirst[7] = 0.0;
            coeffsSecond[1] = sb1;
            coeffsSecond[2] = sb2;
            coeffsSecond[3] = sb3;
            coeffsSecond[4] = sb4;
            coeffsSecond[5] = sb5;
            coeffsSecond[6] = sb6;
            coeffsSecond[7] = sb7;
            coeffsSecond[8] = 0.0;
        }
    }
    // common arithmetic for polynomial expansion 
    Real First = coeffsFirst[7];
    Real Second = coeffsSecond[8];
    for (signed char c=6; c>=0; c--){
#pragma HLS unroll
        First = coeffsFirst[c] + base*First;
    }
    for (signed char c=7; c>=1; c--){
#pragma HLS unroll
        Second = coeffsSecond[c] + base*Second;
    }
    Second = one + base*Second;
    Real F_by_S = First/Second;
    if(ix < 0x3feb0000) { /* |x|<0.84375 */
        return x + x*F_by_S;
    }
    if(ix < 0x3ff40000) { /* 0.84375 <= |x| < 1.25 */
        if(hx>=0) return erx + F_by_S; else return -erx - F_by_S;
    }
    Real z = x;
    *(1-n0+(int*)&z) = 0;
    //double r = exp(-z*z-0.5625)*exp((z-x)*(z+x)+F_by_S);
    double r = exp((double)(-z*z-0.5625+(z-x)*(z+x)+F_by_S));
    Real r_by_x = r*one_by_x;
    if(hx>=0) return one - r_by_x; else return - one - r_by_x;

/*
    if(ix < 0x3feb0000) { // |x|<0.84375
        z = x*x;
        r = pp0+z*(pp1+z*(pp2+z*(pp3+z*pp4)));
        s = one+z*(qq1+z*(qq2+z*(qq3+z*(qq4+z*qq5))));
        y = r/s;
        return x + x*y;
    }
    if(ix < 0x3ff40000) { // 0.84375 <= |x| < 1.25
        s = fabs(x)-one;
        P = pa0+s*(pa1+s*(pa2+s*(pa3+s*(pa4+s*(pa5+s*pa6)))));
        Q = one+s*(qa1+s*(qa2+s*(qa3+s*(qa4+s*(qa5+s*qa6)))));
        if(hx>=0) return erx + P/Q; else return -erx - P/Q;
    }
    x = fabs(x);
    s = one/(x*x);
    if(ix< 0x4006DB6E) { // |x| < 1/0.35
        R=ra0+s*(ra1+s*(ra2+s*(ra3+s*(ra4+s*(ra5+s*(ra6+s*ra7))))));
        S=one+s*(sa1+s*(sa2+s*(sa3+s*(sa4+s*(sa5+s*(sa6+s*(sa7+s*sa8)))))));
    } else { // |x| >= 1/0.35
        R=rb0+s*(rb1+s*(rb2+s*(rb3+s*(rb4+s*(rb5+s*rb6)))));
        S=one+s*(sb1+s*(sb2+s*(sb3+s*(sb4+s*(sb5+s*(sb6+s*sb7))))));
    }
    z = x;
    *(1 - n0 + (int *)&z) = 0;
    r = exp(-z * z - 0.5625) * exp((z - x) * (z + x) + R / S);
    if (hx >= 0)
        return one - r / x;
    else
        return r / x - one;
*/
}
}
#endif
