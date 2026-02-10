pm.input <- function(bone = NULL, ref = NULL, sort = NULL, measurements = NULL, threshold = 1) {

	if (is.null(bone) || is.null(sort) || is.null(ref) || is.null(threshold) || is.null(measurements)) {
		return(NULL)
	}

	meta_cols <- c("accession", "side", "element")

	cnsb <- colnames(sort)
	cb <- duplicated(c(measurements, cnsb), fromLast = TRUE)
	if (!any(cb)) { return(NULL) }
	measurements <- measurements[cb[1:length(measurements)]]

	bone <- tolower(bone)

	# Reference data sorting
	ref$side <- tolower(ref$side)
	ref$element <- tolower(ref$element)
	ref <- ref[ref$element == bone, ]
	ref <- cbind(ref[, meta_cols], ref[measurements])

	# Order and sort by duplicate entries (pair-matches)
	ref <- ref[order(ref$accession), ]
	refleft <- ref[ref$side == "left", ]
	refright <- ref[ref$side == "right", ]
	refleft <- refleft[refleft$accession %in% refright$accession, ]
	refright <- refright[refright$accession %in% refleft$accession, ]

	if (nrow(refleft) == 0 || nrow(refright) == 0) { return(NULL) }

	# Case data sorting
	sort$side <- tolower(sort$side)
	sort$element <- tolower(sort$element)
	sort <- sort[sort$element == bone, ]
	sort <- cbind(sort[, meta_cols], sort[measurements])
	sortleft_t <- sort[sort$side == "left", ]
	sortright_t <- sort[sort$side == "right", ]

	if (nrow(sortleft_t) == 0 || nrow(sortright_t) == 0) { return(NULL) }

	sortleft <- data.frame()
	sortright <- data.frame()
	rejected <- data.frame()

	# Sorting by threshold and saving rejected elements
	for (i in 1:nrow(sortleft_t)) {
		if ((length(measurements) - sum(is.na(sortleft_t[i, c(4:length(measurements))]))) >= threshold) {
			sortleft <- rbind(sortleft, sortleft_t[i, ])
		} else {
			rejected <- rbind(rejected, sortleft_t[i, ])
		}
	}
	for (i in 1:nrow(sortright_t)) {
		if ((length(measurements) - sum(is.na(sortright_t[i, c(4:length(measurements))]))) >= threshold) {
			sortright <- rbind(sortright, sortright_t[i, ])
		} else {
			rejected <- rbind(rejected, sortright_t[i, ])
		}
	}

	if (nrow(sortleft) == 0 || nrow(sortright) == 0) { return(NULL) }

	# Replace NA with zero
	sortleft[is.na(sortleft)] <- 0
	sortright[is.na(sortright)] <- 0
	refleft[is.na(refleft)] <- 0
	refright[is.na(refright)] <- 0
	return(list(refleft, refright, sortleft, sortright, rejected))
}
