# AF3 SLURM pipelines

AlphaFold 3 pipelines for SLURM clusters: one-off predictions, standalone MSA
generation, and large combinatorial interaction screens — all with ipSAE
interface scoring.

| folder | use it when |
|---|---|
| [`default_pipeline/`](#default_pipeline) | you have ready-made JSONs, each a complete job — MSA and inference together |
| [`data_pipeline/`](#data_pipeline) | you want MSAs only, to reuse across many screens |
| [`inference_pipeline/`](#inference_pipeline) | all-vs-all screen over pre-computed MSAs |

MSA search is the expensive step. For anything combinatorial, run
`data_pipeline` once per protein set and then `inference_pipeline` as many
times as you have screens, rather than recomputing MSAs per pair.

---

## default_pipeline

One array task per input JSON. Each task runs AF3 end to end (data pipeline +
inference), scores with ipSAE, and compresses the output.

```
default_pipeline/
  AF3_array_submit.sh    counts JSONs, sizes the array, submits
  AF3_array_job.sh       one task: AF3 → ipSAE → tar.gz
  ipsae.py
```

```bash
bash AF3_array_submit.sh <input_dir> <output_dir>
```

`<input_dir>` is searched recursively for `*.json`, sorted, and one array task
is created per file. Each task writes `<output_dir>/<job_name>.tar.gz` plus
`<output_dir>/ipsae_scores/<job_name>/`.

Self-contained: it does not read `af3_env.sh`. Configuration is a block at the
top of `AF3_array_job.sh`:

| setting | meaning |
|---|---|
| `AF3_BIN` | `run_alphafold.py` path |
| `SCRIPT_DIR` | where `ipsae.py` lives |
| `RUN_IPSAE` | `true`/`false` |
| `IPSAE_MODE` | `all` (every diffusion sample) or `top` (top-level model only) |
| `IPSAE_PAE`, `IPSAE_DIST` | ipSAE cutoffs, default 10 / 10 |
| `REMOVE_DIR_AFTER_TAR` | delete the directory once the archive verifies |

`AF3_array_submit.sh` contains an absolute path to `AF3_array_job.sh` — update
it if you move the scripts.

** For large sets use the data + inference pipelines instead. **

The archive is verified with `tar -tzf` before the original directory is
removed, and ipSAE failures are non-fatal — they are logged to
`<output_dir>/ipsae_failed.tsv` and the prediction is still kept.

---

## data_pipeline

MSA search only (`--run_data_pipeline=true --run_inference=false`). CPU
partition, no GPU.

```
data_pipeline/
  AF3_datapipeline_submit.sh   submit, auto-chunked around MaxArraySize
  AF3_datapipeline_job.sh      one task: MSA search for one JSON
```

```bash
bash AF3_datapipeline_submit.sh --input ./jsons --output ./msa_out \
     [--batch NAME] [--jackhmmer-cpu 8] [--nhmmer-cpu 8] [--dry-run]
```

Output is one directory per protein, which is exactly what the inference
pipeline takes as a chain directory:

```
msa_out/
  NbNRC2/NbNRC2_data.json
  Rx/Rx_data.json
```

---

## inference_pipeline

All-vs-all screen: every chain A input against every chain B input, using
pre-computed MSAs.

```
inference_pipeline/
  af3_env.sh                      ALL configuration lives here
  AF3_screen_submit.sh            build manifest, submit controller
  AF3_controller.sh               chunked array submission
  AF3_inference_pipeline_job.sh   one prediction + ipSAE
  AF3_status.sh                   progress
  AF3_resume.sh                   resubmit what is missing
  AF3_check.sh                    verify install, weights, helper scripts
  AF3_logs.sh                     list / inspect / prune run logs
  AF3_purge.sh                    fast parallel deletion of huge directories
  merge_af3_multimer_v7.py        build the merged input JSON for one pair
  ipsae.py
```

```bash
bash AF3_check.sh

bash AF3_screen_submit.sh --chain-a ./nlrs --chain-b ./effectors \
     --output ./screen_out --batch nrc_screen --seeds "1 2 3"

bash AF3_status.sh --output ./screen_out
bash AF3_resume.sh --output ./screen_out
```

`data_pipeline` scripts source `af3_env.sh` too, so keep both folders' contents
in one directory on the cluster.

### How the pieces fit

`AF3_screen_submit.sh` runs on the login node in seconds: validates inputs,
generates `manifest.tsv`, writes `.af3_screen.conf`, submits the controller.
There is no separate manifest step.

`AF3_controller.sh` runs as a batch job for as long as the screen takes. It
collapses manifest job numbers into contiguous ranges, splits anything over
`MaxArraySize`, and submits one array job per chunk — waiting for each before
submitting the next, so the queue never exceeds `MaxSubmitJobs`. Not run
directly.

`AF3_inference_pipeline_job.sh` is one array task: maps its task ID to a chain
pair (`index_a = task_id / num_B`, `index_b = task_id % num_B`), builds the
input JSON via the merge script, runs inference, scores with ipSAE, compresses.

### Options

| option | effect |
|---|---|
| `--seeds "1 2 3"` | one job, AF3 runs all three seeds |
| `--expand-seeds` | one job per seed instead; adds `_seed<N>` to the name |
| `--protomers-a N` / `--protomers-b N` | copy number per chain, e.g. `6` for a hexamer |
| `--extra-chain PATH[:N]` | constant partner in every job; repeatable; does not multiply the job count |
| `--ipsae-mode all\|top` | every diffusion sample, or only the top model |
| `--ipsae-layout job\|flat` | one `ipsae_scores` subfolder per job, or one directory |
| `--start-chunk N` | manual override; prefer `AF3_resume.sh` |
| `--dry-run` | print what would be submitted; the manifest is still written |

Stoichiometry uses AF3's native id-list syntax (`"id": ["A","B","C"]`), so the
MSA is searched once per entity regardless of copy number. Copy numbers go into
output names (`job_0_NbNRC2x6_AVR2`) so different stoichiometries cannot collide
in one output directory.

Seeds cost time; protomers cost memory, and AF3 memory scales roughly with the
square of token count. The submit script prints chains-per-job and warns above
eight — run one job before committing a whole screen.

### Output

```
screen_out/
  job_0_NbNRC2_Rx.tar.gz          one archive per job
  manifest.tsv                    the job list
  .af3_screen.conf                settings, so status/resume need only --output
  ipsae_scores/
    job_0_NbNRC2_Rx/
      *_seed-1_sample-0_model_10_10.txt
      *_seed-1_sample-0_model_10_10_byres.txt
      *_ranking_scores.csv        which sample ranked top
  ipsae_failed.tsv
```

Aggregating scores needs a recursive glob: `ipsae_scores/*/*_10_10.txt`.

### Resuming

`AF3_resume.sh` compares the manifest against the archives actually on disk and
resubmits exactly the gaps. It is correct wherever the controller stopped, and
catches individual tasks that failed inside a chunk that otherwise finished.

`--start-chunk N` skips by position in the manifest and assumes every task in
the skipped chunks succeeded, which is rarely true after a controller dies
mid-run. Treat it as a manual override.

---

## Configuration

`af3_env.sh` is the only file the data and inference pipelines need edited.
Every value can also be overridden from the environment:

```bash
AF3_SIF=/af3data/containers/af3_3.0.4.sif bash AF3_screen_submit.sh ...
```

| variable | sets |
|---|---|
| `AF3_SIF` | Apptainer image (containerised clusters) |
| `AF3_BIN` | `run_alphafold.py` path (native installs) |
| `AF3_MODEL_DIR` | model parameters |
| `AF3_DB_DIR`, `AF3_PDB_DIR` | genetic databases, template mmCIFs |
| `AF3_GPU_PARTITION`, `AF3_CPU_PARTITION` | inference / MSA partitions |
| `AF3_LOG_ROOT` | where run logs go |
| `AF3_IPSAE_MODE`, `AF3_IPSAE_LAYOUT` | ipSAE scope and output layout |
| `AF3_MERGE_SCRIPT`, `AF3_IPSAE_SCRIPT` | helper script paths |

Keep one copy per cluster: partitions, database paths and whether AF3 is
containerised all differ between sites.

---

## Logs

One directory per run under `AF3_LOG_ROOT`, deliberately not under `$HOME` —
home quotas are small, and when the filesystem fills SLURM kills tasks having
written no log at all.

```
af3_logs/screen_nrc_screen_20260907-143022/
  controller.log                 the chunk loop
  tasks.tsv                      one row per task: id, state, exit, seconds
  tasks/<arrayjob>_<task>.log    stdout AND stderr merged, one file per task
```

```bash
bash AF3_logs.sh list                      # runs, newest first, with fail counts
bash AF3_logs.sh failed  <run>             # just the failures
bash AF3_logs.sh show    <run> <task_id>   # one task's full log
bash AF3_logs.sh tail    <run>             # follow the controller
bash AF3_logs.sh prune --older-than 30     # dry run; add --yes to delete
```

`<run>` takes any unique fragment of the directory name.

Tasks killed by SLURM itself — OOM, timeout, node failure — never reach the
summary step, so they are absent from `tasks.tsv`. Cross-check with
`sacct -j <jobid> --format=JobID,State,ExitCode,Reason,MaxRSS`.

`rm -rf` on a large log tree is slow on NFS (one unlink round trip per file,
serially). `AF3_purge.sh` renames the target first, then unlinks in parallel:

```bash
sbatch AF3_purge.sh --path ~/old_logs          # dry run, counts only
sbatch AF3_purge.sh --path ~/old_logs --yes
```

`default_pipeline` does not use this layout — its `#SBATCH -o/-e` lines write
one file per task wherever the header points.

---

## Notes

Things that cost real debugging time.

**Batch scripts cannot find `af3_env.sh` via `BASH_SOURCE`.** SLURM copies the
batch script to `/var/spool/slurmd/job<id>/` before running it. The
`sbatch`-submitted scripts resolve it in order: `--script-dir` (passed
automatically by the submitters), exported `AF3_SCRIPT_DIR`,
`$SLURM_SUBMIT_DIR`, then `BASH_SOURCE`. Submitting a job script by hand needs
`--script-dir`.

**sbatch options must come before the job script path.** Anything after it is
passed to the job script rather than consumed by sbatch, surfacing as the job
script rejecting an unknown argument.

**Chain directories hold one folder per protein**, not flat JSONs. Inputs are
counted with the same recursive `rglob` the merge script uses for indexing — a
mismatched count silently mis-pairs chains rather than erroring.

**`--force_output_dir` does not set the output directory.** AF3 always appends
`sanitised_name()` of the job name to `--output_dir`; the flag only suppresses
timestamped duplicates. That name was lowercased in 3.0.1 and is case-preserving
from 3.0.2 on, so the job scripts try both and fall back to a glob.

**AF3 JSONs can contain explicit nulls.** `"userCCD": null` and
`"bondedAtomPairs": null` are common in data-pipeline output, and
`dict.get(key, [])` returns the default only when a key is *absent*. The merge
script routes every list lookup through a null-safe helper.

**ipSAE needs numpy.** The plain `python3` on a GPU node often lacks it, which
is the usual reason ipSAE silently does nothing. `AF3_array_job.sh`
auto-detects an interpreter that can import numpy; override with `AF3_PYTHON`.

**Array jobs mail per task.** `--mail-type=BEGIN,END,FAIL` on a 1000-task array
is roughly 3000 emails.

---

## Requirements

- SLURM with array job support
- AlphaFold 3 ≥ 3.0.2, containerised or native. 3.0.2 is the floor: the
  pipelines rely on `--force_output_dir`, `seed-<S>_sample-<N>` sample
  directories, and case-preserving output names
- AF3 model parameters (requested separately from DeepMind, non-commercial
  terms) and genetic databases
- Python 3 with numpy for `ipsae.py`

## Credits

`ipsae.py` is from the Dunbrack lab
([DunbrackLab/IPSAE](https://github.com/DunbrackLab/IPSAE)) — see that repo for
the method and citation.

AlphaFold 3 is by Google DeepMind
([google-deepmind/alphafold3](https://github.com/google-deepmind/alphafold3)).
Model parameters are under DeepMind's terms; the AF3 code is Apache 2.0 from
3.0.3 onward.
