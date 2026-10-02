# Smoke test for a built libosj: loads it through the app's own loader and
# calls every exported function once. Checks results are non-empty and
# finite; it does not check exact values.
#
# Run from the OsteoSort root, with the library unpacked at
# /home/shiny/dist (as in the release workflow):
#   Rscript build/libosj_smoke.R

source("OsteoSort/R/osj.r")
osj_load()

check <- function(name, x) {
    if (length(x) == 0 || !all(is.finite(unlist(x)))) {
        stop(name, ": empty or non-finite result")
    }
    cat("ok", name, "\n")
}

# Reference left/right measurements (right = left + noise) and sorted elements
set.seed(1)
ref_left <- matrix(rnorm(40 * 4, mean = 45, sd = 3), ncol = 4)
ref_right <- ref_left + matrix(rnorm(40 * 4, sd = 0.5), ncol = 4)
sort_left <- ref_left[1:3, ] + 0.2
sort_right <- ref_right[4:6, ] - 0.2

for (absolute in c(FALSE, TRUE)) {
    for (yeojohnson in c(FALSE, TRUE)) {
        for (zeromean in c(FALSE, TRUE)) {
            check(
                sprintf("osj_ttest(absolute=%s, yeojohnson=%s, zeromean=%s)", absolute, yeojohnson, zeromean),
                osj_ttest(sort_left, sort_right, ref_left, ref_right, 2,
                    absolute = absolute, yeojohnson = yeojohnson, zeromean = zeromean)
            )
        }
    }
}

check("osj_ttest_plot", osj_ttest_plot(sort_left[1, , drop = FALSE], sort_right[1, , drop = FALSE], ref_left, ref_right))
check("osj_regsl", osj_regsl(sort_left[, 1:2], sort_right[, 3:4], ref_left[, 1:2], ref_right[, 3:4]))
check("osj_regsl_plot", osj_regsl_plot(sort_left[1, 1:2, drop = FALSE], sort_right[1, 3:4, drop = FALSE], ref_left[, 1:2], ref_right[, 3:4]))

cat("libosj smoke test passed.\n")
