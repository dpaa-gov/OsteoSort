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
