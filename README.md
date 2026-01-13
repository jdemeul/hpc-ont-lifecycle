# hpc-ont-lifecycle

Nextflow workflow for Oxford Nanopore Technologies (ONT) PromethION data lifecycle management on HPC clusters.

## Overview

This workflow orchestrates the complete lifecycle of ONT sequencing data:

1. **Stage** - Downloads raw POD5/FAST5 data from Google Cloud Storage to local scratch
2. **Basecall** - Runs GPU-accelerated basecalling with Dorado
3. **Upload** - Transfers results (uBAM) back to GCS with integrity verification
4. **Cleanup** - Optionally deletes raw data after verified upload

## Features

- **Samplesheet-driven** - Process specific runs via CSV input
- **Per-sample model override** - Use different Dorado models for different samples
- **Quota-aware staging** - Downloads one run at a time to manage scratch space
- **Transactional uploads** - Only deletes raw data after verified upload
- **Safe by default** - Deletion disabled unless explicitly enabled

## Requirements

- **Nextflow** >= 23.04
- **Apptainer** (Singularity) for containerized execution
- **Slurm** workload manager
- **Google Cloud SDK** (`gcloud`) for GCS operations
- **NVIDIA GPU** with CUDA support for basecalling

### GCP Authentication

Create a service account with Storage Object Admin role and download the JSON key:

```bash
export GOOGLE_APPLICATION_CREDENTIALS=~/.gcp/credentials.json
```

## Installation

```bash
git clone https://github.com/jdemeul/hpc-ont-lifecycle.git
cd hpc-ont-lifecycle
```

## Usage

### Samplesheet Format

Create a CSV file with your runs to process:

```csv
sample_id,run_uri,dorado_model
SAMPLE001,gs://my-bucket/runs/20240130_RunID/,
SAMPLE002,gs://my-bucket/runs/20240131_RunID/,dna_r10.4.1_e8.2_400bps_sup@v4.3.0
SAMPLE003,gs://my-bucket/runs/20240201_RunID/,
```

| Column | Required | Description |
|--------|----------|-------------|
| `sample_id` | Yes | Unique identifier for tracking |
| `run_uri` | Yes | GCS path to run directory (must contain `pod5_pass/` or `pod5/`) |
| `dorado_model` | No | Per-sample Dorado model (uses default if empty) |

### Running the Workflow

```bash
# Basic run (no deletion, includes failed reads by default)
nextflow run main.nf \
    -profile slurm \
    --samplesheet samples.csv

# With raw data deletion after successful upload
nextflow run main.nf \
    -profile slurm \
    --samplesheet samples.csv \
    --delete_raw true

# Exclude failed reads from basecalling
nextflow run main.nf \
    -profile slurm \
    --samplesheet samples.csv \
    --include_fail false

# Use a different basecalling model
nextflow run main.nf \
    -profile slurm \
    --samplesheet samples.csv \
    --dorado_model "dna_r10.4.1_e8.2_400bps_hac@v5.0.0"
```

## Configuration

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--samplesheet` | *required* | Path to input CSV file |
| `--dorado_model` | `sup` | Default basecalling model (uses latest SUP model) |
| `--scratch_dir` | `/scratch/$USER/ont-lifecycle` | Local staging directory |
| `--delete_raw` | `false` | Delete raw data after verified upload |
| `--include_fail` | `true` | Include pod5_fail in processing |

### Cluster Configuration

Edit `nextflow.config` to match your HPC environment:

```groovy
process {
    withName: 'STAGE_DATA' {
        queue = 'transfer'      // Partition with internet access
    }
    withName: 'DORADO_BASECALL' {
        queue = 'gpu'           // GPU partition
        clusterOptions = '--gres=gpu:1'
    }
}
```

### Profiles

Profiles can be combined with commas (e.g., `-profile slurm,apptainer`).

**Executor profiles:**
| Profile | Description |
|---------|-------------|
| `slurm` | Run on Slurm cluster (default executor) |
| `local` | Run locally (for testing) |
| `test` | Use test samplesheet |

**Container profiles:**
| Profile | Description |
|---------|-------------|
| `apptainer` | Use Apptainer containers (recommended for HPC) |
| `singularity` | Use Singularity containers (legacy) |
| `docker` | Use Docker containers (requires Docker with GPU support) |

**Example:**
```bash
# Slurm with Apptainer containers
nextflow run main.nf -profile slurm,apptainer --samplesheet samples.csv

# Local with Docker
nextflow run main.nf -profile local,docker --samplesheet samples.csv
```

## Output

For each sample, the workflow produces:
- `{sample_id}.bam` - Unmapped BAM with basecalled reads
- `{sample_id}_sequencing_summary.txt` - Dorado sequencing summary

These files are uploaded to the original GCS run directory.

## Safety Features

The workflow includes multiple safety checks:

1. **Deletion disabled by default** - Must explicitly set `--delete_raw true`
2. **Upload verification** - Compares local and remote file sizes before deletion
3. **Sequential staging** - Only one run downloads at a time (`maxForks 1`)
4. **Integrity checks** - Validates POD5 files after download

## License

MIT
