## BiocJobs job script: deseq2-differential-expression
##
## The declared interface lives in ../deseq2-differential-expression.yaml.
## jobParams() parses the command line against that declaration, so by the
## time it returns, every value below is typed, validated and defaulted.

params <- BiocJobs::jobParams("DESeq2", "deseq2-differential-expression")

suppressPackageStartupMessages(library(DESeq2))

## ---- inputs -------------------------------------------------------------

## quote = "" / comment.char = "": plain TSV, so stray quote characters in
## identifiers cannot silently swallow rows.
counts_df <- read.delim(params$counts, check.names = FALSE, quote = "",
                        comment.char = "")
gene_ids <- as.character(counts_df[[1L]])
if (anyDuplicated(gene_ids))
    stop("duplicate gene identifiers in ", params$counts, ": ",
         paste(utils::head(unique(gene_ids[duplicated(gene_ids)]), 5L),
               collapse = ", "))
counts <- as.matrix(counts_df[, -1L, drop = FALSE])
rownames(counts) <- gene_ids
if (!is.numeric(counts))
    stop("count matrix contains non-numeric values")
if (anyNA(counts))
    stop("count matrix contains missing values (empty or NA cells)")
if (any(counts < 0) || any(counts != round(counts)))
    stop("DESeq2 requires raw integer counts (no TPM/FPKM or ",
         "otherwise normalized values)")
if (max(counts) > .Machine$integer.max)
    stop("counts exceed the integer range")
mode(counts) <- "integer"

coldata <- read.delim(params$coldata, row.names = 1, check.names = FALSE,
                      stringsAsFactors = TRUE, quote = "",
                      comment.char = "")
absent <- setdiff(colnames(counts), rownames(coldata))
if (length(absent))
    stop("samples missing from the sample table: ",
         paste(absent, collapse = ", "))
## Align sample table rows with count matrix columns -- DESeq2 requires it.
coldata <- coldata[colnames(counts), , drop = FALSE]

fac <- params$contrast_factor
if (!fac %in% colnames(coldata))
    stop("contrast factor '", fac, "' is not a column of the sample table")
coldata[[fac]] <- as.factor(coldata[[fac]])
## DESeq2 renames non-syntactic factor levels with make.names(), which would
## desynchronize them from the requested contrast; require clean names.
lvls <- levels(coldata[[fac]])
nonsyntactic <- lvls[lvls != make.names(lvls)]
if (length(nonsyntactic))
    stop("level(s) of '", fac, "' contain characters other than letters, ",
         "numbers, '.' and '_': ",
         paste0("'", nonsyntactic, "'", collapse = ", "),
         "; rename them in the sample table (e.g. 'IFN-gamma' -> ",
         "'IFN_gamma') and rerun")
for (lvl in c(params$contrast_numerator, params$contrast_denominator))
    if (!lvl %in% lvls)
        stop("'", lvl, "' is not a level of '", fac, "' (levels: ",
             paste(lvls, collapse = ", "), ")")

## Reference level = contrast denominator, so that the fitted Wald
## coefficient '<factor>_<numerator>_vs_<denominator>' exists; apeglm
## shrinkage can only operate on a fitted coefficient.
coldata[[fac]] <- stats::relevel(coldata[[fac]],
                                 ref = params$contrast_denominator)

## ---- model --------------------------------------------------------------

dds <- DESeqDataSetFromMatrix(countData = counts, colData = coldata,
                              design = stats::as.formula(params$design))

if (params$prefilter) {
    ## 0 means automatic: the size of the smallest group of the tested
    ## factor, per the DESeq2 vignette's recommendation.
    min_samples <- params$prefilter_min_samples
    if (min_samples == 0L)
        min_samples <- min(table(coldata[[fac]]))
    keep <- rowSums(counts(dds) >= params$prefilter_min_count) >=
        min_samples
    message("pre-filter: keeping ", sum(keep), " of ", length(keep),
            " genes (>= ", params$prefilter_min_count, " counts in >= ",
            min_samples, " samples)")
    dds <- dds[keep, ]
}

dds <- DESeq(dds)

coef <- paste(fac, params$contrast_numerator, "vs",
              params$contrast_denominator, sep = "_")
res <- results(dds,
               contrast = c(fac, params$contrast_numerator,
                            params$contrast_denominator),
               alpha = params$alpha)
res <- switch(params$shrinkage,
    none   = res,
    apeglm = lfcShrink(dds, coef = coef, type = "apeglm", res = res),
    ashr   = lfcShrink(dds, contrast = c(fac, params$contrast_numerator,
                                         params$contrast_denominator),
                       type = "ashr", res = res),
    normal = lfcShrink(dds, coef = coef, type = "normal", res = res)
)

message("significant genes at padj < ", params$alpha, ": ",
        sum(res$padj < params$alpha, na.rm = TRUE))

## ---- outputs ------------------------------------------------------------

res_df <- data.frame(gene_id = rownames(res), as.data.frame(res),
                     check.names = FALSE)
res_df <- res_df[order(res_df$padj), ]
write.table(res_df, params$results, sep = "\t", quote = FALSE,
            row.names = FALSE)

norm <- counts(dds, normalized = TRUE)
write.table(data.frame(gene_id = rownames(norm), norm, check.names = FALSE),
            params$normalized_counts, sep = "\t", quote = FALSE,
            row.names = FALSE)

pdf(params$ma_plot, width = 6, height = 5)
plotMA(res, alpha = params$alpha,
       main = paste0(fac, ": ", params$contrast_numerator, " vs ",
                     params$contrast_denominator,
                     " (", params$shrinkage, ")"))
invisible(dev.off())

## Provenance to the job log.
message(paste(utils::capture.output(utils::sessionInfo()), collapse = "\n"))
