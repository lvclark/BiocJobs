## Simulates a small RNA-seq experiment for exercising the
## deseq2-differential-expression job: 600 genes x 6 samples
## (3 control, 3 treated), negative-binomial counts, 60 genes with a true
## 4-fold change. Deterministic via a fixed seed.

set.seed(20260810)

n_genes <- 600
n_per_group <- 3
n_de <- 60

base_mean <- rlnorm(n_genes, meanlog = 4, sdlog = 1.5)
dispersion <- 0.1 + 2 / base_mean

fold <- rep(1, n_genes)
fold[seq_len(n_de)] <- rep(c(4, 0.25), length.out = n_de)

mu <- cbind(
    matrix(rep(base_mean, n_per_group), ncol = n_per_group),
    matrix(rep(base_mean * fold, n_per_group), ncol = n_per_group)
)

counts <- matrix(
    rnbinom(n_genes * 2 * n_per_group, mu = mu, size = 1 / dispersion),
    nrow = n_genes,
    dimnames = list(
        sprintf("gene%03d", seq_len(n_genes)),
        c(paste0("control_", seq_len(n_per_group)),
          paste0("treated_", seq_len(n_per_group)))
    )
)

coldata <- data.frame(
    sample = colnames(counts),
    condition = rep(c("control", "treated"), each = n_per_group)
)

dir <- dirname(sub("--file=", "", grep("--file=", commandArgs(), value = TRUE)))
write.table(data.frame(gene_id = rownames(counts), counts),
            file.path(dir, "counts.tsv"),
            sep = "\t", quote = FALSE, row.names = FALSE)
write.table(coldata, file.path(dir, "coldata.tsv"),
            sep = "\t", quote = FALSE, row.names = FALSE)
message("wrote ", file.path(dir, "counts.tsv"), " and coldata.tsv")
