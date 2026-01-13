hpc-ont-lifecycle: Hybrid GCS-to-Slurm PromethION Data Workflow
Version: 2.0.0 (HPC Edition)
Platform: Local HPC (Slurm Scheduler) + Google Cloud Storage
Framework: Nextflow (DSL2)
Container Engine: Apptainer (Singularity)

1. Project Overview
This workflow orchestrates the lifecycle of Oxford Nanopore Technologies (ONT) PromethION sequencing data. It bridges the gap between cloud storage and local high-performance computing resources.
Operational Flow:
Watcher: Detects completed runs on Google Cloud Storage (GCS) by checking for COPY_COMPLETE.flag.
Staging: Downloads raw POD5/FAST5 data from GCS to the HPC's high-speed scratch space (one run at a time to manage quotas).
Processing: Submits GPU-accelerated basecalling jobs (dorado) to the Slurm scheduler.
Archival: Uploads the resulting unmapped BAMs (uBAM) back to the original GCS run folder.
Lifecycle: Verifies the upload integrity and destructively deletes the raw POD5/FAST5 files from GCS to minimize storage costs.

2. Infrastructure & Prerequisites
A. HPC Environment
Scheduler: Slurm Workload Manager.
Container Runtime: Apptainer (formerly Singularity). Docker is usually not available on HPC.
Hardware:
Head Node: Minimal resources (to run the Nextflow supervisor).
Transfer Node: High I/O bandwidth for downloading/uploading TB-scale runs.
GPU Node: NVIDIA A100 or V100/T4 with CUDA support for dorado.
Storage: High-performance local scratch (e.g., /scratch or /lustre) is mandatory. Do not run I/O intensive tasks on $HOME.
B. Google Cloud Authentication
Since the HPC nodes cannot open a browser for OAuth, you must use a Service Account Key.
Create a Service Account in GCP with Storage Object Admin role.
Download the JSON key file.
Save it on the HPC (e.g., ~/.gcp/credentials.json).
Critical: The workflow will use the GOOGLE_APPLICATION_CREDENTIALS environment variable to authenticate gcloud inside the jobs.
C. Software
Nextflow: v23.04+
Google Cloud CLI (gcloud): Must be installed on the cluster or provided via a container.
Dorado: Provided via container (ontresearch/dorado).

3. Configuration (nextflow.config)
The configuration must define the Slurm partitions and resource requests.

Groovy


params {
    // Input bucket to watch
    gcs_bucket = "gs://my-lab-bucket/runs"
    
    // Model configuration
    dorado_model = "dna_r10.4.1_e8.2_400bps_hac@v4.3.0"
    
    // Safety Switch (Must be true to delete data)
    delete_raw = false
}

process {
    executor = 'slurm'
    // Default for light tasks (listing, checking)
    queue = 'standard' 
    memory = '8 GB'
    time = '4h'

    withName: 'DOWNLOAD_RUN|UPLOAD_AND_CLEAN' {
        queue = 'transfer' // Or a partition with internet access
        cpus = 4
        memory = '16 GB'
        time = '12h'
    }

    withName: 'DORADO_BASECALL' {
        queue = 'gpu'
        clusterOptions = '--gres=gpu:1' // Request 1 GPU
        containerOptions = '--nv'       // Apptainer flag to bind NVidia drivers
        cpus = 16                       // Dorado needs CPU for IO/alignment
        memory = '64 GB'
        time = '24h'
    }
}

apptainer {
    enabled = true
    autoMounts = true
    runOptions = '--nv' // Global GPU support
}

// Environment variables passed to all jobs
env {
    GOOGLE_APPLICATION_CREDENTIALS = "${HOME}/.gcp/credentials.json"
}


4. Workflow Logic & Module Specifications
To satisfy the "one by one" and "delete" requirements, the workflow passes the GCS URI string (val) rather than letting Nextflow stage the files automatically. This gives us precise control over the deletion logic.
Input Channel
Scans params.gcs_bucket using gcloud storage ls.
Filters for folders containing COPY_COMPLETE.flag.
Emits: val(run_uri) (e.g., gs://bucket/runs/20240130_RunID/).
Process 1: STAGE_DATA
Executor: Slurm (CPU/Transfer node).
Concurrency: maxForks 1 (Ensures only one run is downloaded at a time to prevent filling scratch disk).
Input: val(run_uri)
Commands:
Create a local directory.
gcloud storage cp -r "${run_uri}pod5_pass"./local_run/
gcloud storage cp -r "${run_uri}pod5_fail"./local_run/ (optional).
Integrity: Run pod5 inspect (or pod5 check) on a sample of files to verify download integrity.
Output: path(local_run_dir), val(run_uri)
Process 2: DORADO_BASECALL
Executor: Slurm (GPU node).
Container: ontresearch/dorado:latest.
Input: path(local_run_dir)
Command:
Bash
dorado basecaller \
    ${params.dorado_model} \
    ${local_run_dir} \
    --recursive \
    --emit-moves \
    > ${local_run_dir.name}.bam

# Generate summary
dorado summary ${local_run_dir.name}.bam > sequencing_summary.txt


Output: path("*.bam"), path("sequencing_summary.txt")
Process 3: TRANSACTIONAL_FINISH
Executor: Slurm (CPU/Transfer node).
Input: path(bam), path(summary), val(run_uri)
Logic:
Upload:
Bash
gcloud storage cp ${bam} "${run_uri}"
gcloud storage cp ${summary} "${run_uri}"


Verify:
Check exit code of upload.
Run gcloud storage ls "${run_uri}${bam}" to confirm remote existence and size.
Delete (Atomic Commit):
IF upload verified AND params.delete_raw is true:
gcloud storage rm -r "${run_uri}pod5_pass/"
gcloud storage rm -r "${run_uri}pod5_fail/"
gcloud storage rm "${run_uri}*.fast5" (if legacy).

5. Implementation Checklist for Claude Code
When generating the code, please ensure:
[ ] Validation: The workflow must verify COPY_COMPLETE.flag exists before doing anything.
[ ] GCS Path Handling: Use val(gcs_path) for input channels. Do not use path(gcs_path) as input, or Nextflow will attempt to stage it to the work directory, which duplicates data and complicates the explicit deletion logic.
[ ] Slurm Directives: Use clusterOptions for specific GPU flags (--gres=gpu:x) as these vary by cluster.
[ ] Apptainer Binding: Ensure containerOptions = '--nv' is set for the Dorado process.
[ ] Deletion Safety: Wrap the deletion command in a strict conditional block.
Bash
if [ "$upload_success" = "true" ] && [ "$params.delete_raw" = "true" ]; then
    echo "Deleting raw data..."
    # rm command
else
    echo "Skipping deletion."
fi


6. Quick Start
Login to HPC: ssh user@hpc-cluster
Start Interactive Session: srun --pty -p interactive... bash (Don't run on login node!)
Authenticate: export GOOGLE_APPLICATION_CREDENTIALS=~/.gcp/key.json
Run:
Bash
nextflow run main.nf \
    -profile slurm \
    --gcs_bucket "gs://my-lab/promethion-runs" \
    --delete_raw false


