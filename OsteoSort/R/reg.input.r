reg.input <- function(ref = NULL, sorta = NULL, sortb = NULL, bonea = NULL, boneb = NULL, sidea = NULL, sideb = NULL, threshold = 1, measurementsa = NULL, measurementsb = NULL) {
	meta_cols <- c("accession", "side", "element")

	sidea <- tolower(sidea)
	sideb <- tolower(sideb)
	bonea <- tolower(bonea)
	boneb <- tolower(boneb)

	cnsb <- colnames(sorta)
	cb <- duplicated(c(measurementsa, cnsb), fromLast = TRUE)
	if (!any(cb)) { return(NULL) }
	measurementsa <- measurementsa[cb[1:length(measurementsa)]]
	cnsb <- colnames(sortb)
	cb <- duplicated(c(measurementsb, cnsb), fromLast = TRUE)
	if (!any(cb)) { return(NULL) }
	measurementsb <- measurementsb[cb[1:length(measurementsb)]]

	ref$side <- tolower(ref$side)
	ref$element <- tolower(ref$element)

	refa <- ref[ref$element == bonea, ]
	refa <- refa[refa$side == sidea, ]
	refa <- cbind(refa[, meta_cols], refa[measurementsa])
	refa <- refa[order(refa$accession), ]

	refb <- ref[ref$element == boneb, ]
	refb <- refb[refb$side == sideb, ]
	refb <- cbind(refb[, meta_cols], refb[measurementsb])
	refb <- refb[order(refb$accession), ]

	n_refa <- refa[refa$accession %in% refb$accession, ]
	n_refb <- refb[refb$accession %in% refa$accession, ]

	if (nrow(n_refa) == 0 || nrow(n_refb) == 0) { return(NULL) }

	sorta$side <- tolower(sorta$side)
	sorta$element <- tolower(sorta$element)
	sortb$side <- tolower(sortb$side)
	sortb$element <- tolower(sortb$element)

	sorta <- sorta[sorta$element == bonea, ]
	sorta <- sorta[sorta$side == sidea, ]
	sorta <- cbind(sorta[, meta_cols], sorta[measurementsa])

	sortb <- sortb[sortb$element == boneb, ]
	sortb <- sortb[sortb$side == sideb, ]
	sortb <- cbind(sortb[, meta_cols], sortb[measurementsb])

	if (nrow(sorta) == 0 || nrow(sortb) == 0) { return(NULL) }

	sort_A <- data.frame()
	sort_B <- data.frame()
	rejected <- data.frame()

	for (i in 1:nrow(sorta)) {
		if ((length(measurementsa) - sum(is.na(sorta[i, c(4:length(measurementsa))]))) >= threshold) {
			sort_A <- rbind(sort_A, sorta[i, ])
		} else {
			rejected <- rbind(rejected, sorta[i, ])
		}
	}
	for (i in 1:nrow(sortb)) {
		if ((length(measurementsb) - sum(is.na(sortb[i, c(4:length(measurementsb))]))) >= threshold) {
			sort_B <- rbind(sort_B, sortb[i, ])
		} else {
			rejected <- rbind(rejected, sortb[i, ])
		}
	}

	if (nrow(sort_A) == 0 || nrow(sort_B) == 0) { return(NULL) }

	sort_A[is.na(sort_A)] <- 0
	sort_B[is.na(sort_B)] <- 0
	n_refa[is.na(n_refa)] <- 0
	n_refb[is.na(n_refb)] <- 0

	return(list(n_refa, n_refb, sort_A, sort_B, rejected))
}
