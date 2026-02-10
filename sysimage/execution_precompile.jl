using RCall
using GLM
using Rmath
using Optim
using Statistics
using Suppressor
using Pkg
using OSJ

left = rand(20,4)
right = rand(20,4)
ref_left = rand(20,4)
ref_right = rand(20,4)

# Plot function — precompile all flag combinations
TTEST_plot(left, right, ref_left, ref_right)
TTEST_plot(left, right, ref_left, ref_right, absolute=true)
TTEST_plot(left, right, ref_left, ref_right, yeojohnson=true)
TTEST_plot(left, right, ref_left, ref_right, absolute=true, yeojohnson=true)

# Precompile with floating point tails (as JuliaCall passes from R)
tails = 2.0

TTEST(left, right, ref_left, ref_right, tails)
TTEST(left, right, ref_left, ref_right, tails, absolute=true)
TTEST(left, right, ref_left, ref_right, tails, yeojohnson=true)
TTEST(left, right, ref_left, ref_right, tails, zeromean=true)
TTEST(left, right, ref_left, ref_right, tails, absolute=true, yeojohnson=true)
TTEST(left, right, ref_left, ref_right, tails, absolute=true, zeromean=true)
TTEST(left, right, ref_left, ref_right, tails, yeojohnson=true, zeromean=true)
TTEST(left, right, ref_left, ref_right, tails, absolute=true, yeojohnson=true, zeromean=true)

# Precompile with integer tails
tails = 2

TTEST(left, right, ref_left, ref_right, tails)
TTEST(left, right, ref_left, ref_right, tails, absolute=true)
TTEST(left, right, ref_left, ref_right, tails, yeojohnson=true)
TTEST(left, right, ref_left, ref_right, tails, zeromean=true)
TTEST(left, right, ref_left, ref_right, tails, absolute=true, yeojohnson=true)
TTEST(left, right, ref_left, ref_right, tails, absolute=true, zeromean=true)
TTEST(left, right, ref_left, ref_right, tails, yeojohnson=true, zeromean=true)
TTEST(left, right, ref_left, ref_right, tails, absolute=true, yeojohnson=true, zeromean=true)

# Regression
REGSL(left, right, ref_left, ref_right)
REGSL_plot(left, right, ref_left, ref_right)