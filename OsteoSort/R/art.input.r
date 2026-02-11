art.input <- function(bonea = NULL, boneb = NULL, side = NULL, ref = NULL, sorta = NULL, sortb = NULL, measurementsa = NULL, measurementsb = NULL, threshold = 1) {
    if (is.null(bonea) || is.null(boneb) || is.null(sorta) || is.null(sortb)) {
        return(NULL)
    }

    meta_cols <- c("accession", "side", "element")

    side <- tolower(side)
    ref$side <- tolower(ref$side)
    ref$element <- tolower(ref$element)

    cnsb <- colnames(sortb)
    cb <- duplicated(c(measurementsb, cnsb), fromLast = TRUE)
    if (!any(cb)) {
        return(NULL)
    }
    measurementsb <- measurementsb[cb[seq_along(measurementsb)]]
    cnsb <- colnames(sorta)
    cb <- duplicated(c(measurementsa, cnsb), fromLast = TRUE)
    if (!any(cb)) {
        return(NULL)
    }
    measurementsa <- measurementsa[cb[seq_along(measurementsa)]]

    refa <- ref[ref$element == bonea, ]
    refb <- ref[ref$element == boneb, ]

    refa <- refa[refa$side == side, ]
    refb <- refb[refb$side == side, ]
    refa <- cbind(refa[, meta_cols], refa[measurementsa])
    refb <- cbind(refb[, meta_cols], refb[measurementsb])
    refa <- refa[order(refa$accession), ]
    refb <- refb[order(refb$accession), ]

    n_refa <- refa[refa$accession %in% refb$accession, ]
    n_refb <- refb[refb$accession %in% refa$accession, ]

    if (nrow(n_refa) == 0 || nrow(n_refb) == 0) {
        return(NULL)
    }

    sorta$side <- tolower(sorta$side)
    sorta$element <- tolower(sorta$element)
    sorta <- sorta[sorta$element == bonea, ]
    sorta <- sorta[sorta$side == side, ]
    sorta <- cbind(sorta[, meta_cols], sorta[measurementsa])

    sortb$side <- tolower(sortb$side)
    sortb$element <- tolower(sortb$element)
    sortb <- sortb[sortb$element == boneb, ]
    sortb <- sortb[sortb$side == side, ]
    sortb <- cbind(sortb[, meta_cols], sortb[measurementsb])

    if (nrow(sorta) == 0 || nrow(sortb) == 0) {
        return(NULL)
    }

    sort_A <- data.frame()
    sort_B <- data.frame()
    rejected <- data.frame()

    for (i in seq_len(nrow(sorta))) {
        if ((length(measurementsa) - sum(is.na(sorta[i, c(4:length(measurementsa))]))) >= threshold) {
            sort_A <- rbind(sort_A, sorta[i, ])
        } else {
            rejected <- rbind(rejected, sorta[i, ])
        }
    }
    for (i in seq_len(nrow(sortb))) {
        if ((length(measurementsb) - sum(is.na(sortb[i, c(4:length(measurementsb))]))) >= threshold) {
            sort_B <- rbind(sort_B, sortb[i, ])
        } else {
            rejected <- rbind(rejected, sortb[i, ])
        }
    }

    if (nrow(sort_A) == 0 || nrow(sort_B) == 0) {
        return(NULL)
    }

    sort_A[is.na(sort_A)] <- 0
    sort_B[is.na(sort_B)] <- 0
    n_refa[is.na(n_refa)] <- 0
    n_refb[is.na(n_refb)] <- 0

    return(list(n_refa, n_refb, sort_A, sort_B, rejected))
}
