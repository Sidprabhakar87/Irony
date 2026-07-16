# Synaptyx Intelligence — ML Roadmap

## Current State (v0.1.0): Rule-Based Heuristics

The current system uses **hardcoded thresholds and pattern matching**:
- Referee: Input change counting, array similarity comparison, position bounds
- Coach: Ratio-based playstyle classification, frame count comparisons

This is intentional for the MVP — it allows shipping quickly while collecting
data needed for proper ML model training.

---

## Phase 1: Data Collection Infrastructure (Next)

**Goal:** Collect and store labeled training data from real tournaments.

### What to Collect
| Data Type | Source | Storage |
|---|---|---|
| Input sequences (per frame) | IPC frame stream | Parquet files |
| Animation sequences | IPC frame stream | Parquet files |
| Match outcomes | Tournament platform API | PostgreSQL |
| Known violations (labeled) | Tournament admin reports | PostgreSQL |
| Player behavior profiles | Aggregated from frames | Feature store |

### Privacy & Compliance
- All data anonymized before storage (no player names/accounts)
- Players consent at tournament registration
- Data retained for max 90 days unless player opts in to longer
- GDPR-compliant deletion on request
- No data collected from ranked/online play — tournament only

### Implementation
```
synaptyx_intelligence/
├── data/
│   ├── collector.py       # Frame data collector (writes to disk)
│   ├── anonymizer.py      # Remove PII before storage
│   ├── schema.py          # Parquet/DB schema definitions
│   └── storage.py         # Storage backend (local/S3)
```

### Tekken 8 EULA Compliance
- Data is collected from tournament-organized matches only
- No game files are extracted or distributed
- Frame data is ephemeral game state, not copyrighted content
- Tool is deployed by tournament organizers, not individual players

---

## Phase 2: Referee ML Models (v0.2.0)

**Goal:** Replace hardcoded thresholds with trained anomaly detection.

### Model 1: Input Anomaly Detector

| Aspect | Details |
|---|---|
| **Architecture** | Autoencoder (encoder-decoder) on input sequences |
| **Input** | Sliding window of 60 frames of input state (1 second) |
| **Output** | Reconstruction error score (high = anomalous) |
| **Training data** | 10,000+ matches of legitimate gameplay |
| **Threshold** | 99.5th percentile of reconstruction error = violation |
| **Framework** | PyTorch → export to ONNX for inference |

**Why autoencoder:** Learns the distribution of "normal" human input patterns.
Macros and bots produce inputs outside this distribution, yielding high
reconstruction error without needing labeled cheat examples.

### Model 2: Macro Pattern Classifier

| Aspect | Details |
|---|---|
| **Architecture** | 1D CNN on animation ID sequences |
| **Input** | Sequence of 30 animation IDs |
| **Output** | Binary classification: human vs macro |
| **Training data** | Synthetic macros + real human sequences |
| **Framework** | scikit-learn (SVM) for v1, PyTorch CNN for v2 |

### Training Pipeline
```
1. Collect frames from 50+ tournaments (Phase 1)
2. Label known violations (from admin reports)
3. Generate synthetic macro data (known patterns)
4. Train autoencoder on "clean" data only
5. Validate on held-out violations
6. Export to ONNX Runtime for inference
7. A/B test: run ML alongside rules, compare results
8. Gradual rollout: ML confidence > 0.95 → auto-flag
```

### Training Schedule
- **NOT real-time** — models are trained offline
- Retraining: Weekly batch job on collected data
- Deployment: Manual approval before new model goes live
- Rollback: Previous model version always available

---

## Phase 3: Coach ML Models (v0.3.0)

**Goal:** Replace ratio-based classification with learned models.

### Model 3: Opponent Style Embeddings

| Aspect | Details |
|---|---|
| **Architecture** | Transformer encoder on match sequences |
| **Input** | Full match frame sequence (variable length) |
| **Output** | 32-dim style embedding vector |
| **Clustering** | k-means on embeddings → discover playstyle clusters |
| **Framework** | PyTorch Transformer |

Instead of 4 hardcoded playstyles, the model learns a continuous
style space where similar players cluster together naturally.

### Model 4: Punish Recommendation Engine

| Aspect | Details |
|---|---|
| **Architecture** | Lookup table (v1) → Sequence model (v2) |
| **Input** | Opponent's move, recovery frames, character matchup |
| **Output** | Ranked list of optimal punishes with expected damage |
| **Data source** | Pro player match data + frame data databases |
| **Framework** | Simple lookup for v1, neural for v2 |

### Model 5: Win Probability Predictor

| Aspect | Details |
|---|---|
| **Architecture** | Gradient Boosted Trees (XGBoost) |
| **Input** | Current match state features (health, round, momentum) |
| **Output** | Probability of winning from current state |
| **Use case** | "Comeback potential" metric in coaching reports |

---

## Phase 4: Advanced Features (v1.0.0)

### Real-Time Opponent Adaptation
- During a match, track how opponent's behavior changes round-to-round
- Detect when opponent "downloads" your patterns
- Alert: "Opponent has adapted to your d/f+2 punish — vary timing"

### Character-Specific Models
- Per-character move databases with frame data
- Matchup-specific counter-strategy models
- Trained on high-rank player data per character

### Tournament Integrity Score
- Aggregate referee confidence across entire tournament
- Flag players whose behavior drifts from their historical profile
- "This player's inputs today are statistically different from their last 10 tournaments"

---

## Technical Stack for ML

```
Training:
  - PyTorch (model training)
  - Weights & Biases (experiment tracking)
  - DVC (data versioning)
  - Scheduled via Airflow or simple cron

Inference:
  - ONNX Runtime (fast CPU inference in production)
  - Optional: TensorRT for GPU-accelerated inference
  - Model served within the Python FastAPI service

Storage:
  - Parquet files for frame data (efficient columnar storage)
  - PostgreSQL for match metadata and labels
  - S3/MinIO for model artifacts
```

---

## Timeline Estimate

| Phase | Duration | Prerequisites |
|---|---|---|
| Phase 1: Data Collection | 2-3 weeks | Hybrid architecture deployed |
| Phase 2: Referee ML | 6-8 weeks | 50+ tournaments of data collected |
| Phase 3: Coach ML | 4-6 weeks | Phase 2 complete + pro player data |
| Phase 4: Advanced | 8-12 weeks | All previous phases |

---

## Key Principles

1. **Rules first, ML second** — Ship with heuristics, upgrade with data
2. **Offline training only** — Never train during live matches
3. **Human in the loop** — ML flags, humans confirm violations
4. **Explainable** — Every ML decision must have a human-readable reason
5. **Privacy by design** — Anonymize, consent, delete on request
6. **No competitive advantage** — ML insights are post-match only (coach) or organizer-only (referee)
