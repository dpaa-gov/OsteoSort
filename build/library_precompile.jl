# Precompile script for shared library build
# Stripped-down version of execution_precompile.jl — no RCall/Suppressor needed
using OSJ

left = rand(20, 4)
right = rand(20, 4)
ref_left = rand(20, 4)
ref_right = rand(20, 4)

# TTEST — all flag combinations
tails = 2.0
TTEST(left, right, ref_left, ref_right, tails)
TTEST(left, right, ref_left, ref_right, tails, absolute=true)
TTEST(left, right, ref_left, ref_right, tails, yeojohnson=true)
TTEST(left, right, ref_left, ref_right, tails, zeromean=true)
TTEST(left, right, ref_left, ref_right, tails, absolute=true, yeojohnson=true)
TTEST(left, right, ref_left, ref_right, tails, absolute=true, zeromean=true)
TTEST(left, right, ref_left, ref_right, tails, yeojohnson=true, zeromean=true)
TTEST(left, right, ref_left, ref_right, tails, absolute=true, yeojohnson=true, zeromean=true)

# TTEST with integer tails
tails_int = 2
TTEST(left, right, ref_left, ref_right, tails_int)

# TTEST_plot
TTEST_plot(left, right, ref_left, ref_right)
TTEST_plot(left, right, ref_left, ref_right, absolute=true)
TTEST_plot(left, right, ref_left, ref_right, yeojohnson=true)
TTEST_plot(left, right, ref_left, ref_right, absolute=true, yeojohnson=true)

# Regression
REGSL(left, right, ref_left, ref_right)
REGSL_plot(left, right, ref_left, ref_right)

# C wrappers — the R .C() path, so their result-copying code is compiled in
let out = zeros(length(left)^2), t = [2.0], I = Cint[size(left)..., size(left, 1)^2, length(out), 0, 0, 1]
    GC.@preserve left right ref_left ref_right out t I begin
        ip(i) = pointer(I, i)
        mats = (x for m in (left, right, ref_left, ref_right) for x in (pointer(m), ip(1), ip(2)))
        OSJ.osj_ttest(mats..., pointer(t), ip(7), ip(7), ip(7), pointer(out), ip(3), ip(5), ip(6))
        OSJ.osj_ttest_plot(mats..., ip(7), ip(7), pointer(out), ip(4), ip(6))
        OSJ.osj_regsl(mats..., pointer(out), ip(3), ip(5), ip(6))
        OSJ.osj_regsl_plot(mats..., pointer(out), ip(4), ip(5), ip(6))
    end
end
