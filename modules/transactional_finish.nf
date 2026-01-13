/*
 * TRANSACTIONAL_FINISH: Upload results and optionally delete raw data
 *
 * Key design decisions:
 * - Transactional approach: only delete after verified upload
 * - Deletion requires explicit params.delete_raw = true
 * - Verifies upload by checking remote file existence and size
 */

process TRANSACTIONAL_FINISH {
    tag "${sample_id}"

    input:
    tuple val(sample_id), path(bam), path(summary), val(run_uri)
    val(delete_raw)

    output:
    tuple val(sample_id), val(run_uri), emit: completed

    script:
    """
    #!/bin/bash
    set -euo pipefail

    echo "========================================="
    echo "Transactional Finish"
    echo "Sample ID: ${sample_id}"
    echo "Run URI: ${run_uri}"
    echo "BAM: ${bam}"
    echo "Summary: ${summary}"
    echo "Delete Raw: ${delete_raw}"
    echo "========================================="

    upload_success="false"

    # Get local file sizes for verification
    local_bam_size=\$(stat -c%s "${bam}" 2>/dev/null || stat -f%z "${bam}")
    local_summary_size=\$(stat -c%s "${summary}" 2>/dev/null || stat -f%z "${summary}")

    echo "Local BAM size: \${local_bam_size} bytes"
    echo "Local summary size: \${local_summary_size} bytes"

    # Upload BAM file
    echo "Uploading BAM file..."
    if gcloud storage cp "${bam}" "${run_uri}"; then
        echo "BAM upload command succeeded"
    else
        echo "ERROR: BAM upload failed"
        exit 1
    fi

    # Upload summary file
    echo "Uploading summary file..."
    if gcloud storage cp "${summary}" "${run_uri}"; then
        echo "Summary upload command succeeded"
    else
        echo "ERROR: Summary upload failed"
        exit 1
    fi

    # Verify uploads
    echo "Verifying uploads..."

    # Check BAM exists and has correct size
    remote_bam_info=\$(gcloud storage ls -l "${run_uri}${bam}" 2>/dev/null | head -1)
    if [ -n "\${remote_bam_info}" ]; then
        remote_bam_size=\$(echo "\${remote_bam_info}" | awk '{print \$1}')
        echo "Remote BAM size: \${remote_bam_size} bytes"

        if [ "\${remote_bam_size}" = "\${local_bam_size}" ]; then
            echo "BAM size verification: PASSED"
        else
            echo "WARNING: BAM size mismatch (local: \${local_bam_size}, remote: \${remote_bam_size})"
            echo "Upload verification FAILED - will not delete raw data"
            exit 1
        fi
    else
        echo "ERROR: Cannot verify remote BAM file"
        exit 1
    fi

    # Check summary exists
    if gcloud storage ls "${run_uri}${summary}" &>/dev/null; then
        echo "Summary verification: PASSED"
    else
        echo "ERROR: Cannot verify remote summary file"
        exit 1
    fi

    upload_success="true"
    echo "All uploads verified successfully"

    # Conditional deletion of raw data
    if [ "\${upload_success}" = "true" ] && [ "${delete_raw}" = "true" ]; then
        echo "========================================="
        echo "DELETING RAW DATA"
        echo "========================================="

        # Delete pod5_pass
        if gcloud storage ls "${run_uri}pod5_pass/" &>/dev/null; then
            echo "Deleting pod5_pass..."
            gcloud storage rm -r "${run_uri}pod5_pass/"
            echo "pod5_pass deleted"
        fi

        # Delete pod5_fail
        if gcloud storage ls "${run_uri}pod5_fail/" &>/dev/null; then
            echo "Deleting pod5_fail..."
            gcloud storage rm -r "${run_uri}pod5_fail/"
            echo "pod5_fail deleted"
        fi

        # Delete pod5 (alternative naming)
        if gcloud storage ls "${run_uri}pod5/" &>/dev/null; then
            echo "Deleting pod5..."
            gcloud storage rm -r "${run_uri}pod5/"
            echo "pod5 deleted"
        fi

        # Delete legacy fast5 files
        if gcloud storage ls "${run_uri}fast5_pass/" &>/dev/null; then
            echo "Deleting fast5_pass..."
            gcloud storage rm -r "${run_uri}fast5_pass/"
            echo "fast5_pass deleted"
        fi

        if gcloud storage ls "${run_uri}fast5_fail/" &>/dev/null; then
            echo "Deleting fast5_fail..."
            gcloud storage rm -r "${run_uri}fast5_fail/"
            echo "fast5_fail deleted"
        fi

        # Delete any loose fast5 files
        echo "Checking for loose FAST5 files..."
        if gcloud storage ls "${run_uri}*.fast5" &>/dev/null; then
            gcloud storage rm "${run_uri}*.fast5"
            echo "Loose FAST5 files deleted"
        fi

        echo "Raw data deletion complete"
    else
        if [ "${delete_raw}" != "true" ]; then
            echo "Skipping deletion: delete_raw is not enabled"
        else
            echo "Skipping deletion: upload verification failed"
        fi
    fi

    echo "========================================="
    echo "Transactional Finish Complete"
    echo "Sample ID: ${sample_id}"
    echo "Run: ${run_uri}"
    echo "Upload Success: \${upload_success}"
    echo "Raw Data Deleted: ${delete_raw}"
    echo "========================================="
    """
}
