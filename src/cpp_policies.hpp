// presage:helper Rounding round_nearest round_zero round_up round_down
// Named policies are integer constants in the generated helper interfaces.
enum Rounding { round_nearest = 0, round_zero = 1, round_up = 2, round_down = 3 };
// presage:helper Overflow overflow_reject overflow_saturate overflow_wrap
enum Overflow { overflow_reject = 0, overflow_saturate = 1, overflow_wrap = 2 };
