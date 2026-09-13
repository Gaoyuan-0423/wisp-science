# Wisp Science: Complete an Upstream RNA-seq Analysis

After finding a public RNA-seq dataset, how do you turn raw sequencing files into a count matrix suitable for differential expression analysis?

This tutorial uses Wisp Science to organize samples, prepare FASTQ files, check quality, align reads, and count genes. We use **ESR1 knockdown in MCF7 cells from GSE153250**, retaining only siESR1 and siNT samples. The outputs are gene counts, a sample group table, and a counting summary.

The English prompts below are the actual requests used for these tasks and can be copied directly into a Wisp conversation.

## 1. Prepare the project and compute server

Create a Wisp Science project, such as `ESR1`, and choose a workspace for analysis records, scripts, and retrieved outputs. See [Quick Start](wisp-science-quick-start.md) for model configuration.

This upstream analysis runs on a remote Linux server. Follow the [server tutorial](wisp-science-servers-cli.md) to register your own SSH server in Settings and verify connectivity.

Allow enough disk space for downloads, uncompressed FASTQ files, references, and intermediate BAMs. STAR also needs memory appropriate to the index size. This workflow does not require a GPU; CPU, memory, storage, and networking are the main resources.

Wisp should first check these tools:

| Tool | Purpose |
| --- | --- |
| SRA Toolkit: `prefetch`, `fasterq-dump` | Download SRA data and convert it to FASTQ |
| FastQC | Inspect sequencing quality and adapter content |
| cutadapt | Remove adapters, trim low-quality ends, and discard short reads |
| STAR | Align reads to the reference genome |
| samtools | Inspect and process BAM files |
| featureCounts | Generate counts using gene annotation |

SSH connectivity does not establish software, reference, or storage readiness. Execution must use your own environment and verified paths.

## 2. Understand the samples first

The selected dataset is **GSE153250**. Before downloading, ask Wisp to organize samples by treatment:

```text
What specific samples are included in GSE153250? Please organize them by treatment group.
```

The dataset contains siNT, siESR1, siGATA3, and siTET2. We retain the first two groups to study ESR1 knockdown relative to control:

| Group | Samples | Included here? |
| --- | --- | --- |
| siNT | 6 | Yes, control |
| siESR1 | 6 | Yes, ESR1 knockdown |
| siGATA3 | 6 | No |
| siTET2 | 6 | No |

To estimate download size and understand the processing steps, ask:

```text
If I reanalyze the raw sequencing data, approximately how much data would I need to download, and what steps would be required for the analysis?
```

Distinguish **samples** from **sequencing runs**. These are single-end, 50 bp reads, with each sample split across multiple lanes/runs. The selected 12 samples each have 8 SRR runs, giving **96 SRRs** to organize.

There are 12 sample columns in the final count matrix, not 96 independent biological replicates. Recalculate storage requirements for the selected groups rather than treating a whole-dataset estimate as the actual requirement for this subset.

## 3. Request the upstream analysis

Once the server is configured and the scope is clear, send:

```text
Connect to the remote compute host, locate the FASTQ data for GSE153250, keep only the siESR1 and siNT groups, and exclude all other groups. Perform transcriptome upstream analysis to obtain the Counts data.
```

The request specifies execution location, dataset, included and excluded groups, and the final output. Wisp inspects the server and locates existing FASTQ files, then downloads and organizes missing inputs using the sample-to-SRR mapping.

Check that the intended samples are retained. The selected GSM accessions are:

| siNT | siESR1 |
| --- | --- |
| GSM4636683 | GSM4636684 |
| GSM4636687 | GSM4636688 |
| GSM4636691 | GSM4636692 |
| GSM4636695 | GSM4636696 |
| GSM4636699 | GSM4636700 |
| GSM4636703 | GSM4636704 |

The columns list two groups side by side; rows do not establish pairing. Verify SRR mappings, treatment, and sequencing layout from metadata and save a manifest that drives merging and counting.

## 4. Download and verify all FASTQ inputs

SRA Toolkit downloads and converts the data. Long-running download tasks execute remotely; inspect their status and logs, then compare the expected SRRs with actual files.

The first attempt succeeded for **95 of 96 SRRs**. The missing run, **SRR12090795**, belongs to GSM4636692 in the siESR1 group. Retrying that run completed all 96 files.

Do not silently proceed with a missing lane just because most files downloaded. Identify the failure and complete the input set before producing that sample's final merged FASTQ.

After downloading, check:

- Every expected SRR exists, with no unexplained failures or duplicates.
- Files are nonempty, compressed files are intact, and FASTQ records are parseable.
- Run-to-GSM and treatment mappings are correct.
- The data are single-end and have not been processed using a paired-end file layout.

An existing file is not necessarily a usable file. Incomplete downloads must not be skipped solely because their paths already exist.

## 5. Merge lanes, inspect quality, and trim adapters

Merge each sample's 8 lanes according to its GSM mapping, producing 12 sample-level FASTQ inputs.

Merge technical data from the same sample only. Do not combine all siNT samples or all siESR1 samples into a single file: that would discard biological replicate information needed for later statistics.

The sequence used here is **lane merging → FastQC → cutadapt**.

FastQC inspects the merged reads. Interpret per-base quality, adapters, length distribution, GC, and duplication in the context of RNA-seq. A warning alone does not establish sample failure; highly expressed transcripts can contribute to elevated duplication.

This analysis uses FastQC 0.12.1 and cutadapt 5.0. cutadapt removes TruSeq adapters with quality threshold 20 and minimum retained length 20 bp. Inspect logs for retained reads, adapter removal, and reads discarded for being too short.

These settings belong to this dataset. Verify the actual library adapters for your own data. With 50 bp reads, excessive trimming can remove substantial information. Post-trimming QC can be added to compare cleaned reads with the original quality reports.

## 6. Align with STAR

The cleaned FASTQ files are aligned to **GRCh38** using **STAR 2.7.11b**, producing coordinate-sorted BAM files.

Before alignment, verify:

| Check | Why it matters |
| --- | --- |
| Species and assembly | Human reads must not use another species' reference found on the server |
| FASTA, GTF, and index provenance | Counting needs annotation compatible with the alignment reference |
| STAR/index compatibility | An existing index may not work with the current STAR version |

The server had a `refdata-gex-GRCh38-2024-A` reference directory, but the first alignment failed with STAR exit code 105. Its error log identified an incompatible `star` index built by **STAR 2.7.1a**, while the current executable was **2.7.11b**.

A compatible `star_v11b` index was available in the reference directory. Switching to it allowed processing to continue. This diagnosis comes from the specific error log; not every exit code 105 necessarily means index incompatibility.

Verified merging, QC, and trimming outputs can be reused when resuming at alignment. If no compatible index is available, assess rebuilding it or using a matching STAR version, recording software and reference details.

This analysis uses an existing reference bundle. Using full GENCODE or another annotation can change the included gene set and final row count. Record the exact reference source rather than merely writing “GRCh38.”

After alignment, inspect each sample's STAR `Log.final.out`, comparing input reads, unique mappings, multimappers, and unmapped reads. Check BAM integrity and readability. No single mapping-rate cutoff replaces interpretation of QC, species, reference, and library characteristics.

## 7. Generate gene counts with featureCounts

With BAMs ready, featureCounts assigns aligned reads to annotated genes.

This analysis uses **featureCounts 2.0.6**, counting exon regions and aggregating by `gene_id`, with **reverse-stranded** library settings.

Strandedness is a critical parameter. A mismatch with the library can reduce assignment substantially. For your own experiment, use library information or strandedness inference to choose the setting rather than copying this example's reverse-stranded configuration.

Also verify single-end versus paired-end layout and record multimapping and overlapping-feature policies. These choices affect count definitions and must be consistent across samples.

featureCounts produces counts and an assignment summary. To build the clean matrix, remove coordinate, length, and other annotation columns from the raw output, retaining a gene ID column and one count column per sample. Map BAM paths to sample names explicitly.

The output is **raw gene counts**, not TPM, FPKM, or log-transformed expression.

## 8. Check readiness for downstream analysis

The main outputs are:

| File | Purpose |
| --- | --- |
| `data/processed/GSE153250_counts_matrix.tsv` | Gene count matrix |
| `data/processed/GSE153250_sample_groups.txt` | Sample group table |
| `data/processed/GSE153250_featureCounts_summary.txt` | featureCounts assignment summary |

The matrix contains **38,606 genes and 12 samples**. Its first column is `Geneid`, followed by `siNT_1` through `siNT_6` and `siESR1_1` through `siESR1_6`. Different references and annotations may produce different gene counts; this row count is a case result, not a universal acceptance target.

The tab-separated group file has `sample` and `group` headers. Before finishing, verify:

- Matrix names and metadata match one to one, with correct ordering and 6 samples per group.
- There are no accidental duplicate gene IDs, missing values, or negative/noninteger counts.
- Sample totals and assignment patterns have no unexplained outliers.
- Assigned and Unassigned categories in the counting summary have been inspected.
- Groups, GSMs, SRRs, FASTQs, and BAMs remain traceable to each other.

Large FASTQs, BAMs, and indexes can stay on the server. Retrieve counts, metadata, the counting summary, and necessary QC reports into the local project. Preserve scripts, logs, software versions, and reference provenance for troubleshooting and reruns.

Use [Trajectory](wisp-science-trajectory.md) to inspect commands and errors, alongside remote run status. The download retry and index correction illustrate why outputs need verification at each stage; a final “complete” message does not replace checking files.

The sequencing runs are now organized into gene counts by biological sample. Continue with this matrix, metadata, and QC records in the [differential expression, ORA, and GSEA tutorial](wisp-science-rnaseq-downstream.md).
