# aiNAT · Species Vision Lab

A local application for teaching and evaluating visual trait classifiers for **any species and your own categories**, using **your own GPT-6.1 Sol API key**. Search iNaturalist or upload photos, label examples, build a classifier recipe, evaluate confidence thresholds, and classify a batch with manual review.

The app runs in your browser on `127.0.0.1`. It is a single-user local program, not a hosted multi-user service. Your API key and project data stay on your computer. Photos and chosen teaching examples are sent to OpenAI only when you explicitly start identification or evaluation.

## Install and run

Requires **R 4.3+**, **Python 3.11+**, and Internet access. macOS and Linux are supported. Model access and API billing must be enabled in your own OpenAI project; a ChatGPT subscription does not provide API credits.

1. Download this repository with **Code → Download ZIP**, or clone it:

   ```sh
   git clone https://github.com/jomhoff/aiNAT.git
   cd aiNAT
   ```

2. **macOS:** install R and Python if needed, then double-click `Setup.command`. If scripts are not executable after a ZIP download, run `zsh Setup.command` from this folder. Setup installs Pillow and the R packages used by the app.

   **Linux:** install R, a compiler toolchain, Python/venv, and the development libraries needed for R's curl, SSL, XML and ImageMagick packages. On Debian/Ubuntu:

   ```sh
   sudo apt-get install r-base r-base-dev build-essential python3-venv libcurl4-openssl-dev libssl-dev libxml2-dev libmagick++-dev
   bash setup.sh
   ```

3. Launch with `Launch.command` on macOS, or `bash launch.sh` on Linux. Alternatively:

   ```sh
   Rscript -e "shiny::runApp('.',host='127.0.0.1',port=7460,launch.browser=TRUE)"
   ```

4. Click **Set up my API key** and paste **your full secret OpenAI key** into the local app. You can also run `Configure OpenAI.command` or `.venv/bin/python openai_key_setup.py` in a terminal. The hidden prompt saves it outside the repository with owner-only permissions. Never commit a key or paste one into an issue.

Use one app instance at a time. Keep the app open during a job. Closing its browser session requests a stop; completed API answers are cached for resuming.

## Choose your species and what to classify

Click **New project / settings**:

- Name the project.
- Search for any species by common or scientific name and choose an iNaturalist match. A typed name without a match supports local uploads.
- Describe the visible trait you want classified.
- Define 2–12 mutually exclusive categories using `key | display name | visible distinguishing features`, one per line. Example:

  ```text
  striped | Striped | A distinct longitudinal stripe on the visible back
  unstriped | Unstriped | The back is clearly visible and lacks a longitudinal stripe
  ```

Each project has separate labels, photos, classifier versions, cached API answers, evaluation reports and results. A permanent **Needs review** outcome prevents forcing unclear photos into your categories. Category keys and species cannot be changed within an existing project; create a new project for a different classification scheme.

## 1. Load and label

Choose a region and **Load observations**, or expand **Or upload your own photos**. JPEG, PNG and WebP are supported. Research Grade only is on by default for iNaturalist; local uploads have no iNaturalist grade and remain eligible. Older saved records with unknown grades must be reloaded before appearing under that filter.

Use the photo viewer and zoom controls. Click a category to save your label and advance. Notes are optional; saving notes never confirms an AI suggestion. Label at least 5 independent observations per category to prepare a demonstration, and aim for 50+ per category for useful evaluation. Include varied lighting, poses and backgrounds. Label only what is actually visible.

## 2. Train / build a classifier recipe

Open **Train & evaluate → Train / build classifier**. This is **example-based prompting, not model-weight fine-tuning**. The app freezes your task, category definitions, labeled teaching examples and data split as a versioned recipe. Building the recipe downloads/normalizes photos but makes no AI requests.

Observations are split approximately 60% teaching, 20% calibration and 20% test within each category. Exact duplicate image hashes are grouped across observations to prevent their crossing splits; conflicting labels on identical images stop training. Up to two representative teaching photographs per category are included in each future request. Calibration/test labels and images are never supplied as teaching examples.

Different photographs can still show the same animal or near-duplicates. The split does not establish biological, geographic or observer independence. Closely related observations should be audited before scientific use.

## 3. Evaluate and select confidence thresholds

Click **Evaluate & select thresholds** to send only the frozen calibration/test target photos to Sol, alongside the teaching examples. This uses your API credits and the cost stop on the Classify tab. Saved answers are reusable if evaluation is stopped and resumed.

Sol returns a category, a brief visual explanation, a **self-assessed score from 0–100**, and whether the distinguishing feature is visible. **The score is not a calibrated probability.** A score of 95 does not imply 95% accuracy.

For each predicted category, the app searches fixed integer cutoffs from 50–100 on calibration data, requiring at least 10 accepted examples and at least 98% observed agreement. If no cutoff qualifies, that category is review-only. This selected empirical accuracy is not a guarantee. Small datasets may yield no accepted automatic labels.

The frozen test then reports agreement among accepted labels, mistakes and review coverage without selecting thresholds on that test. The exported report includes approximate Wilson intervals and per-predicted-category results. Once evaluated, that test is no longer untouched. Further tuning using its failures requires a fresh independent audit. Confidence thresholds are tied to the exact recipe version.

## 4. Classify and review

In **Classify**, choose a batch size and estimated run-cost stop, then **Start / resume batch**. **Validated thresholds** is the default; unvalidated custom recipes send results to review. An **Exploratory confidence cutoff** lets you inspect how a threshold changes coverage, without new API requests for saved scores. It is explicitly not a validated accuracy claim.

Every photo of an observation must agree on the same category and show the relevant feature; the observation score is the minimum photo score. Unclear, conflicting or unreadable photos go to review. Human-labeled observations are skipped in ordinary batches. Human labels always take priority over suggestions on the map and in exports.

Use the review queues to inspect uncertain results or suggestions awaiting confirmation. Click an AI result row to open the photo. The CSVs retain raw suggestions, accepted categories, scores, human labels and quality grades. Project settings, images, recipe versions and answers are saved under `data/` and are excluded from Git.

## API keys, privacy and cost

Each person supplies their **own** OpenAI API key. No author key or shared service credentials are included. Keys are stored in `~/.config/species-vision-lab/openai-api-key` by default, outside the app. Existing salamander installations can continue using their earlier local key path. `OPENAI_API_KEY` can be used instead; `SPECIES_VISION_KEY_FILE` overrides the key-file location. Environment keys take precedence over saved keys.

Only photo pixels, your task/category definitions and chosen labeled teaching examples are included in classification requests. Observation coordinates, notes, target human labels and previous answers are excluded. Requests use `store=false`; this does not itself constitute a zero-retention agreement. OpenAI's account data controls still apply.

API cost varies with photo resolution, example count, output and reasoning tokens. Example-taught recipes cost more than a single-photo prompt. The displayed estimate extrapolates a prior salamander pilot and scales for reference-image count; it is approximate. The cost stop uses recorded usage and fixed reference rates of $2/M input, $0.10/M cached input and $10/M output tokens. Check current provider pricing. Up to four requests can already be in flight, so this is not a hard billing cap. Network interruptions can incur usage without yielding a reusable answer. No paid requests are automatically retried.

This app is designed for local use by one operating-system account. Do not expose the Shiny port publicly or use this key-file design as a multi-user hosted authentication system.

Official API documentation: [image input](https://developers.openai.com/api/docs/guides/images-vision), [structured output](https://developers.openai.com/api/docs/guides/structured-outputs), [data controls](https://developers.openai.com/api/docs/guides/your-data).

## Existing salamander work

The original red-backed/lead-backed project and its legacy Sol prompt remain available. Existing labels, images, cached paid answers and past local-model experiments are preserved in an existing installation. The baseline's 315-photo test matched 272 labels, disagreed on 10 and marked 33 uncertain: 96.45% agreement among 282 assignments. That result does **not** apply to new species, example-taught recipes or confidence policies.

The baseline has no numeric confidence scores. Build/evaluate a new recipe to use confidence-based acceptance. Changing the recipe invalidates automatic reuse of predictions from another configuration. Older answers remain on disk but are not presented as current-version predictions.

No photos, labels, trained recipes, cached answers or historical evaluation datasets are distributed in this repository. Users create their own projects and teaching examples. iNaturalist images retain their original licenses and attribution. Research Grade is an observation-quality designation, not verification of your custom trait labels.

## Verification

```sh
.venv/bin/python -m unittest test_sol_classifier.py test_project_model.py
Rscript check.R
```

Tests use temporary data, synthetic photographs and mocked API responses. They cover independent splits, duplicate grouping, versioned caches, API failures, stop/resume, confidence gates, per-project data isolation, custom categories, grade filtering, manual priority and private key-file permissions. No API key or paid request is required for these checks. They verify execution and data handling, not biological accuracy on arbitrary species.

License: MIT. This application is not affiliated with iNaturalist or OpenAI.
