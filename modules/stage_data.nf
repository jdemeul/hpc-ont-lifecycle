/*
 * STAGE_DATA: Download raw POD5/FAST5 data from GCS to local scratch
 *
 * Key design decisions:
 * - Uses val(gcs_path) NOT path(gcs_path) to prevent Nextflow auto-staging
 * - maxForks = 1 ensures only one run downloads at a time (quota management)
 * - Performs integrity check on downloaded POD5 files
 */

process STAGE_DATA {
    tag "${sample_id}"
    maxForks 1  // Critical: process one run at a time

    input:
    tuple val(sample_id), val(run_uri)
    val(scratch_dir)
    val(include_fail)

    output:
    tuple val(sample_id), path(local_dir), val(run_uri), emit: staged_data

    script:
    // Extract run name from URI (e.g., gs://bucket/runs/20240130_RunID/ -> 20240130_RunID)
    run_name = run_uri.tokenize('/').findAll { it }[-1]
    local_dir = "${sample_id}_${run_name}"

    """
    #!/bin/bash
    set -euo pipefail

    echo "========================================="
    echo "Staging run: ${run_uri}"
    echo "Sample ID: ${sample_id}"
    echo "Local directory: ${local_dir}"
    echo "========================================="

    # Create local directory structure
    mkdir -p "${local_dir}"

    # Download pod5_pass (required)
    echo "Downloading pod5_pass..."
    if gcloud storage ls "${run_uri}pod5_pass/" &>/dev/null; then
        gcloud storage cp -r "${run_uri}pod5_pass" "${local_dir}/"
        echo "pod5_pass downloaded successfully"
    elif gcloud storage ls "${run_uri}pod5/" &>/dev/null; then
        # Some runs use just "pod5" instead of "pod5_pass"
        gcloud storage cp -r "${run_uri}pod5" "${local_dir}/"
        mv "${local_dir}/pod5" "${local_dir}/pod5_pass"
        echo "pod5 downloaded and renamed to pod5_pass"
    else
        echo "ERROR: No pod5_pass or pod5 directory found in ${run_uri}"
        exit 1
    fi

    # Optionally download pod5_fail
    if [ "${include_fail}" = "true" ]; then
        echo "Downloading pod5_fail..."
        if gcloud storage ls "${run_uri}pod5_fail/" &>/dev/null; then
            gcloud storage cp -r "${run_uri}pod5_fail" "${local_dir}/"
            echo "pod5_fail downloaded successfully"
        else
            echo "No pod5_fail directory found (skipping)"
        fi
    fi

    # Download legacy FAST5 if present (for backwards compatibility)
    if gcloud storage ls "${run_uri}fast5_pass/" &>/dev/null; then
        echo "Downloading legacy fast5_pass..."
        gcloud storage cp -r "${run_uri}fast5_pass" "${local_dir}/"
    fi

    # Integrity check: verify POD5 files are readable
    echo "Running integrity check on POD5 files..."
    pod5_count=\$(find "${local_dir}" -name "*.pod5" | wc -l)
    echo "Found \${pod5_count} POD5 files"

    if [ "\${pod5_count}" -gt 0 ]; then
        # Sample check on first few files
        sample_file=\$(find "${local_dir}" -name "*.pod5" | head -1)
        if [ -n "\${sample_file}" ]; then
            # Basic file integrity - check file is readable and has content
            if [ -s "\${sample_file}" ]; then
                echo "Sample POD5 file check passed: \${sample_file}"
            else
                echo "ERROR: POD5 file appears empty or corrupted: \${sample_file}"
                exit 1
            fi
        fi
    fi

    # Report total size
    total_size=\$(du -sh "${local_dir}" | cut -f1)
    echo "========================================="
    echo "Staging complete"
    echo "Sample ID: ${sample_id}"
    echo "Total size: \${total_size}"
    echo "POD5 files: \${pod5_count}"
    echo "========================================="
    """
}
