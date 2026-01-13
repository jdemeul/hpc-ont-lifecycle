#!/usr/bin/env nextflow

/*
 * hpc-ont-lifecycle: Hybrid GCS-to-Slurm PromethION Data Workflow
 * Version: 2.0.0 (HPC Edition)
 *
 * Orchestrates the lifecycle of ONT PromethION sequencing data:
 * 1. Reads runs from a samplesheet CSV
 * 2. Stages raw POD5/FAST5 data to local scratch
 * 3. Runs GPU-accelerated basecalling with Dorado
 * 4. Uploads results and optionally deletes raw data
 */

nextflow.enable.dsl = 2

// Import modules
include { STAGE_DATA } from './modules/stage_data'
include { DORADO_BASECALL } from './modules/dorado_basecall'
include { TRANSACTIONAL_FINISH } from './modules/transactional_finish'

// Parameter validation
if (!params.samplesheet) {
    error "ERROR: --samplesheet is required. Example: --samplesheet 'samples.csv'"
}

// Validate samplesheet exists
samplesheet_file = file(params.samplesheet)
if (!samplesheet_file.exists()) {
    error "ERROR: Samplesheet not found: ${params.samplesheet}"
}

// Log startup info
log.info """
=========================================
 hpc-ont-lifecycle v2.0.0
=========================================
 Samplesheet    : ${params.samplesheet}
 Dorado Model   : ${params.dorado_model} (default)
 Scratch Dir    : ${params.scratch_dir}
 Delete Raw     : ${params.delete_raw}
 Include Fail   : ${params.include_fail}
=========================================
"""

/*
 * Parse samplesheet and create input channel
 *
 * Expected CSV format:
 *   sample_id,run_uri[,dorado_model]
 *
 * Example:
 *   sample_id,run_uri,dorado_model
 *   SAMPLE001,gs://bucket/runs/20240130_RunID/,dna_r10.4.1_e8.2_400bps_sup@v4.3.0
 *   SAMPLE002,gs://bucket/runs/20240131_RunID/,
 */
def parseSamplesheet(samplesheet_path) {
    Channel
        .fromPath(samplesheet_path)
        .splitCsv(header: true, strip: true)
        .map { row ->
            // Validate required fields
            if (!row.sample_id) {
                error "ERROR: Missing 'sample_id' in samplesheet row: ${row}"
            }
            if (!row.run_uri) {
                error "ERROR: Missing 'run_uri' in samplesheet row: ${row}"
            }

            // Ensure run_uri ends with /
            def run_uri = row.run_uri.endsWith('/') ? row.run_uri : "${row.run_uri}/"

            // Use per-sample model if provided, otherwise use default
            def model = row.dorado_model?.trim() ? row.dorado_model.trim() : params.dorado_model

            // Return tuple: [sample_id, run_uri, dorado_model]
            return tuple(row.sample_id, run_uri, model)
        }
}

/*
 * Main workflow
 */
workflow {
    // Parse samplesheet into channel of [sample_id, run_uri, dorado_model]
    samples_ch = parseSamplesheet(params.samplesheet)

    // Log samples being processed
    samples_ch.view { sample_id, run_uri, model ->
        "Processing: ${sample_id} | ${run_uri} | Model: ${model}"
    }

    // Stage data from GCS to local scratch (one at a time via maxForks)
    // Input: [sample_id, run_uri]
    // Output: [sample_id, local_dir, run_uri]
    STAGE_DATA(
        samples_ch.map { sample_id, run_uri, model -> tuple(sample_id, run_uri) },
        params.scratch_dir,
        params.include_fail
    )

    // Join staged data with model info for basecalling
    // STAGE_DATA.out.staged_data: [sample_id, local_dir, run_uri]
    // samples_ch: [sample_id, run_uri, model] -> [sample_id, model]
    // Result: [sample_id, local_dir, run_uri, model]
    staged_with_model = STAGE_DATA.out.staged_data
        .join(samples_ch.map { sample_id, run_uri, model -> tuple(sample_id, model) })

    // Run Dorado basecalling on GPU
    // Input: [sample_id, local_dir, run_uri, model]
    // Output: [sample_id, bam, summary, run_uri]
    DORADO_BASECALL(staged_with_model)

    // Upload results and optionally delete raw data
    // Input: [sample_id, bam, summary, run_uri]
    // Output: [sample_id, run_uri]
    TRANSACTIONAL_FINISH(
        DORADO_BASECALL.out.results,
        params.delete_raw
    )
}

workflow.onComplete {
    log.info """
=========================================
 Workflow completed!
 Status   : ${workflow.success ? 'SUCCESS' : 'FAILED'}
 Duration : ${workflow.duration}
=========================================
    """
}
