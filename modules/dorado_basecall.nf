/*
 * DORADO_BASECALL: GPU-accelerated basecalling using ONT Dorado
 *
 * Key design decisions:
 * - Runs on GPU partition with --nv flag for Apptainer
 * - Outputs unmapped BAM (uBAM) format
 * - Generates sequencing summary for QC
 * - Supports per-sample model override via samplesheet
 */

process DORADO_BASECALL {
    tag "${sample_id}"
    container 'docker://ontresearch/dorado:latest'

    input:
    tuple val(sample_id), path(local_dir), val(run_uri), val(dorado_model)

    output:
    tuple val(sample_id), path("${sample_id}.bam"), path("${sample_id}_sequencing_summary.txt"), val(run_uri), emit: results

    script:
    """
    #!/bin/bash
    set -euo pipefail

    echo "========================================="
    echo "Dorado Basecalling"
    echo "Sample ID: ${sample_id}"
    echo "Run: ${local_dir}"
    echo "Model: ${dorado_model}"
    echo "========================================="

    # Check GPU availability
    if command -v nvidia-smi &>/dev/null; then
        echo "GPU Info:"
        nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv
    else
        echo "WARNING: nvidia-smi not found, GPU may not be available"
    fi

    # Find input directory (pod5_pass or pod5)
    input_dir=""
    if [ -d "${local_dir}/pod5_pass" ]; then
        input_dir="${local_dir}/pod5_pass"
    elif [ -d "${local_dir}/pod5" ]; then
        input_dir="${local_dir}/pod5"
    else
        # Fall back to searching for pod5 files directly
        input_dir="${local_dir}"
    fi

    echo "Input directory: \${input_dir}"
    echo "POD5 files found: \$(find \${input_dir} -name '*.pod5' | wc -l)"

    # Run Dorado basecaller
    echo "Starting basecalling..."
    dorado basecaller \\
        "${dorado_model}" \\
        "\${input_dir}" \\
        --recursive \\
        --emit-moves \\
        > "${sample_id}.bam"

    echo "Basecalling complete"

    # Verify BAM file was created
    if [ ! -s "${sample_id}.bam" ]; then
        echo "ERROR: BAM file is empty or was not created"
        exit 1
    fi

    bam_size=\$(du -h "${sample_id}.bam" | cut -f1)
    echo "BAM file size: \${bam_size}"

    # Generate sequencing summary
    echo "Generating sequencing summary..."
    dorado summary "${sample_id}.bam" > "${sample_id}_sequencing_summary.txt"

    # Report summary stats
    if [ -s "${sample_id}_sequencing_summary.txt" ]; then
        read_count=\$(tail -n +2 "${sample_id}_sequencing_summary.txt" | wc -l)
        echo "Total reads: \${read_count}"
    fi

    echo "========================================="
    echo "Basecalling complete"
    echo "Sample ID: ${sample_id}"
    echo "Output: ${sample_id}.bam"
    echo "Summary: ${sample_id}_sequencing_summary.txt"
    echo "========================================="
    """
}
