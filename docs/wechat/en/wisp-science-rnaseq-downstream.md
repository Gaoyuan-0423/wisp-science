# Wisp Science Hands-on: Complete a Downstream RNA-seq Analysis

How can we investigate the changes in gene expression and transcriptional programs after ESR1 knockdown in breast cancer cells?

In this tutorial, we use Wisp Science to analyze **ESR1 knockdown in MCF7 cells**. We find public data, inspect samples and groups, obtain counts from raw sequencing data, run differential expression, ORA, and GSEA, and turn the findings into testable research questions.

The workflow follows one dataset, **GSE153250**. The prompts below are the exact English requests used for these tasks and can be copied directly into a conversation.

## 1. Prepare the project and execution environment

Follow [Quick Start](wisp-science-quick-start.md) to configure a model, then create a project such as `ESR1` with a workspace for data, scripts, and results.

For this analysis, upstream sequencing processing and R analysis run on a remote Linux server. The local project organizes conversations and stores retrieved outputs. Register your own SSH server in Settings using the [server tutorial](wisp-science-servers-cli.md), and verify connectivity before starting.

Model configuration determines how Wisp interprets the task; server configuration determines where code executes. R, STAR, featureCounts, and other tools must be checked in that environment. A working SSH connection does not establish dependency readiness.

If you already have counts and sample metadata, start at section 4. Downstream count analysis does not require a GPU and can run locally on a CPU with the necessary dependencies. Remote execution is useful here because the workflow also processes raw reads.

## 2. Find data suited to the research question

We are interested in ESR1 and its coregulatory factors, so we specify the cell type, perturbation, and preferred study design:

```text
Help me find RNA-seq knockdown datasets involving ESR1 and its coregulatory factors in MCF7 cells. Prefer datasets that include multiple knockdown conditions within the same study.
```

The request narrows the search to MCF7 cells, knockdown experiments involving ESR1 and its coregulators, and studies containing multiple knockdown conditions.

From the candidates, we select **GSE153250**, which includes siNT, siESR1, siGATA3, and siTET2. This supports an ESR1-focused comparison and leaves room for later comparisons with other regulators.

Next, ask for sample details:

```text
What specific samples are included in GSE153250? Please organize them by treatment group.
```

Then check whether the available files can be used directly for differential expression:

```text
Can this dataset be used directly for differential expression analysis? First, check the file format and any limitations that might affect the analysis.
```

The question is what the values represent, not simply whether a file can be opened. A conventional DESeq2 gene-count workflow needs raw counts. TPM, FPKM, and log-transformed expression values cannot be substituted for raw integer counts.

To plan reprocessing from raw sequencing data, ask:

```text
If I reanalyze the raw sequencing data, approximately how much data would I need to download, and what steps would be required for the analysis?
```

Distinguish sequencing runs from biological samples. In this dataset, multiple lanes/runs belong to each sample and must be organized upstream. They are technical data, not independent biological replicates. Confirm groups, GSM accessions, and run mappings from metadata rather than inferring them from filenames.

## 3. Select groups and generate counts

The first comparison is specific: **what changes in siESR1 relative to siNT?** Keep the knockdown and control groups, excluding siGATA3 and siTET2 for this analysis.

Send:

```text
Connect to the remote compute host, locate the FASTQ data for GSE153250, keep only the siESR1 and siNT groups, and exclude all other groups. Perform transcriptome upstream analysis to obtain the Counts data.
```

This request identifies the execution environment, dataset, included and excluded groups, and expected output. Wisp checks the server, locates or prepares inputs, and performs upstream processing.

The analysis merges sequencing lanes by sample, checks quality with FastQC, processes reads with cutadapt, aligns to GRCh38 with STAR, and produces gene counts with featureCounts.

After upstream processing, check three key outputs:

| File | Purpose |
| --- | --- |
| `data/processed/GSE153250_counts_matrix.tsv` | Gene count matrix |
| `data/processed/GSE153250_sample_groups.txt` | Sample-to-group mapping |
| `data/processed/GSE153250_featureCounts_summary.txt` | Count assignment summary |

Directories may differ between workspaces. Verify actual file locations before downstream analysis rather than reusing another machine's absolute paths.

The matrix contains **38,606 genes and 12 samples**, with Ensembl gene IDs in the first column, `Geneid`:

| Group | Samples | Role |
| --- | --- | --- |
| siNT | `siNT_1` through `siNT_6` | Control and reference level |
| siESR1 | `siESR1_1` through `siESR1_6` | ESR1 knockdown |

The groups file is tab-separated with `sample` and `group` columns. Verify one-to-one matching and correct order between matrix columns and metadata. Check nonnegative integer counts, missing values, duplicate IDs, and unusual library totals.

Matching numeric suffixes do not establish pairing. Incorporate batch or pairing information when supported by metadata, and document missing information as a limitation.

## 4. Request the downstream analysis

With counts ready, request differential expression, enrichment, and GSEA together:

```text
Based on the upstream Counts data from GSE153250, perform transcriptome downstream analysis: differential expression, enrichment analysis, and GSEA. Download Enrichr libraries for human gene sets as needed and use them as GMT files for enrichment.
```

This is the complete downstream task prompt. It specifies the analytical goals and permits downloading human gene sets from Enrichr as GMT files without requiring the user to write the R script first.

Wisp needs to turn that request into observable work: verify inputs and execution context, check R packages, prepare gene sets, run DEG/ORA/GSEA, create figures, and organize methods and outputs.

The main tools used are:

| Analysis | Tool | Check |
| --- | --- | --- |
| Differential expression | DESeq2 | Raw counts, design, reference, and contrast |
| Gene annotation | org.Hs.eg.db | Ensembl-to-Symbol mapping |
| Overrepresentation analysis | clusterProfiler | Foreground, background, and GMT ID space |
| Preranked GSEA | fgsea | Complete signed ranking, duplicate genes, and set sizes |
| Plotting | ggplot2 and related packages | Agreement between labels, thresholds, and tables |

If no SSH context is available, check the server configuration in Settings before continuing. Install missing R packages and verify that they load. Dependency and gene-set download failures should remain visible in execution records.

Enrichr libraries can change or become unavailable. Record the library name, source, retrieval date, and checksum for each GMT. This tutorial focuses on `MSigDB_Hallmark_2020`; downloading every available library is not necessary for a first analysis.

## 5. Inspect differential expression and sample relationships

The contrast is **siESR1 relative to siNT**. Positive `log2FoldChange` means higher expression in knockdown samples; negative values mean lower expression.

This analysis uses:

| Parameter | Setting |
| --- | --- |
| Design | `~ condition`, with siNT as reference |
| Contrast | `siESR1` vs `siNT` |
| Low-count filter | Total counts across all samples ≥10 |
| Multiple-testing correction | BH, `alpha=0.05` |
| DEG selection | `padj < 0.05` and `abs(log2FoldChange) > 0.5` |
| PCA input | DESeq2 VST, `blind=FALSE` |

`condition` is the script's grouping variable, derived from sample metadata. Total counts ≥10 does not mean at least 10 counts in at least six samples. This is the rule used here; other experiments may warrant a different filter.

The LFC cutoff selects results and is not equivalent to an `lfcThreshold` hypothesis test. Record whether LFC shrinkage is used to avoid mixing result definitions.

The results are:

| Metric | Result |
| --- | --- |
| Genes retained after filtering | 19,885 |
| Upregulated DEGs | 3,761 |
| Downregulated DEGs | 4,314 |
| ESR1 `log2FoldChange` | Approximately −3.14 |

Lower ESR1 expression is consistent with the knockdown treatment. Interpreting the broader DEG list requires effect sizes, expression levels, and functional analysis.

Next, inspect PCA:

![GSE153250 PCA showing siNT and siESR1 separated along PC1](../../assets/tutorials/en/rnaseq-downstream/01-pca.png)

The groups separate along PC1. Variance percentages are rounded to integers, so `PC2: 0%` does not mean exactly zero variance. PCA helps inspect relationships and unusual samples, but separation alone cannot rule out batch effects, and an unusual point should not automatically be removed.

Volcano and MA plots show relationships between effect size, significance, and expression level. Recalculate DEG totals from the full result table using consistent thresholds. Retain and explain `padj=NA` rows, excluding indeterminate entries from significance counts.

## 6. ORA: which functional sets contain more differential genes?

ORA asks whether differential genes occur more often in a functional set than expected relative to this experiment's analyzable background.

Analyze upregulated and downregulated genes separately to distinguish directions. The upregulated Hallmark ORA yields **15 terms with `p.adjust < 0.05`**, including a TNFα/NF-κB-related gene set worth closer inspection.

Check two details before interpreting enrichment.

First, ID spaces must match. If a GMT uses gene Symbols, foreground and background lists must use compatible Symbols rather than Ensembl or Entrez IDs. Record unmapped genes and one-to-many mapping policies.

Second, the background should represent genes that this experiment can detect, test, and map, rather than indiscriminately including all human genes. Save foreground and background lists, explain NA handling, and report the effective background after intersection with the GMT.

Overrepresentation is a statistical association, not experimental proof that a pathway is activated. It also does not mean every member gene changes in the same direction.

## 7. GSEA: inspect coordinated directional changes

DEG selection depends on cutoffs. GSEA uses a complete signed gene ranking to find gene sets concentrated at either end of the list.

This analysis ranks genes using DESeq2 **Wald stat**, not just significant DEGs. For repeated Symbols, retain the row with the largest absolute statistic and sort by signed stat in descending order. This policy can favor stronger signals and belongs in the methods. Handle missing and nonfinite statistics before analysis.

The main parameters are `minSize=10`, `maxSize=500`, `nPermSimple=10000`, and random seed `123`. Also record fgsea version, actual algorithm, and parallel configuration. A random seed alone does not guarantee identical results across environments.

Positive NES indicates enrichment toward higher expression in knockdown samples; negative NES indicates enrichment toward lower expression.

![GSE153250 Hallmark GSEA showing selected pathways by NES direction](../../assets/tutorials/en/rnaseq-downstream/02-gsea.png)

The plot shows selected terms, not exclusively terms meeting `padj < 0.05`. Determine significance from the full result table.

Hallmark GSEA tests 50 gene sets, with **25 meeting `padj < 0.05`**. Relevant results include:

| Gene set | NES | padj | Direction |
| --- | --- | --- | --- |
| Estrogen Response Early | −2.247 | 5.66 × 10⁻¹² | Toward the lower end |
| Estrogen Response Late | −2.208 | 2.55 × 10⁻¹¹ | Toward the lower end |
| TNF-alpha Signaling via NF-kB | +2.035 | 5.10 × 10⁻⁸ | Toward the higher end |
| E2F Targets | −1.684 | 3.28 × 10⁻⁴ | Toward the lower end |
| G2-M Checkpoint | −1.647 | 6.12 × 10⁻⁴ | Toward the lower end |

Together, lower ESR1 expression, negative estrogen-response enrichment, and changes in cell-cycle and inflammatory transcriptional programs provide leads for further research.

Moving from expression changes to a mechanism for resistance or disease progression requires inspection of leading-edge genes, independent data, and experiments. One MCF7 knockdown analysis cannot establish patient benefit or treatment efficacy.

## 8. Check the outputs

Open the actual files rather than relying solely on the final conversation summary.

| Directory or file | Check |
| --- | --- |
| `data/raw/GSE153250_counts_matrix.tsv` | Input copy used downstream |
| `results/tables/DESeq2_full_results.csv` | Full differential expression results and annotation |
| `results/tables/ranked_genes.tsv` | Ranking used for GSEA |
| `results/tables/ORA_up_MSigDB_Hallmark_2020.csv` | Upregulated-gene ORA |
| `results/tables/ORA_down_MSigDB_Hallmark_2020.csv` | Downregulated-gene ORA |
| `results/tables/GSEA_MSigDB_Hallmark_2020.csv` | Full Hallmark GSEA results |
| `figures/` | PCA, volcano, MA, ORA, and GSEA plots |
| `analysis/DEG/README.md` | DEG inputs, parameters, and methods |
| `analysis/enrichment/README.md` | Libraries, background, and ORA methods |
| `analysis/GSEA/README.md` | Ranking, parameters, and GSEA methods |
| `results/reports/sessionInfo.txt` | R environment and package versions |

Cross-check DEG counts, ESR1 direction, and pathway statistics against figures and summaries. Preserve GMT files, scripts, logs, and version information. Retrieve required tables and figures after remote computation finishes.

This workflow also required plotting corrections: a completed statistical table does not establish that every figure was written successfully. Use [Trajectory](wisp-science-trajectory.md) to inspect tool inputs and errors, distinguish statistical from plotting failures, and reuse verified tables to finish plotting.

## 9. Develop research questions from the findings

With counts, differential expression, and pathway results available, ask Wisp to propose follow-up projects:

```text
Based on the Counts data from our study, along with the differential expression analysis and pathway enrichment analysis results, design 10 research projects. For each project, clearly state the core findings/evidence basis, scientific question, clinical significance, study design, and key highlights/novelty. Use literature retrieval if necessary to support your hypotheses.
```

The request asks each project to identify supporting evidence, a scientific question, clinical significance, study design, and novelty, with literature retrieval where needed.

Directions include TNFα/NF-κB, p53, Notch–EMT, EPHA2, metabolic reprogramming, ECM/FAK, transcriptional networks, and GREB1. They are candidates for discussion and prioritization. Producing ten proposals does not validate ten mechanisms.

For each promising direction, ask which data row or gene group supports it, which critical evidence is missing, and which experimental outcome would support or refute the hypothesis.

Apply the same process to your own experiments: define the question and samples, run the analysis, and retain figures, methods, and the evidence behind your interpretation.
