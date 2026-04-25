import Foundation

/// Cosine distance threshold below which two items count as the same story.
/// Calibration with nomic-embed-text on news title+lead pairs:
///   0.00–0.05  same article restated
///   0.06–0.12  same story, different outlets / paraphrased headline
///   0.15–0.30  same topic, different angle
///   0.30+      unrelated
/// 0.08 keeps wire-service syndications and obvious paraphrases together
/// without collapsing genuinely different angles on the same topic.
let DUP_DISTANCE_THRESHOLD: Double = 0.08

/// How far back to scan for a cluster head. Beyond this, restatements get to
/// surface again — recurring stories don't deserve to be silenced forever.
let DUP_RECENCY_HOURS: Int = 48

/// Pick a canonical item id from nearest-neighbor candidates.
///
/// Caller passes neighbors sorted by ascending cosine distance (the natural
/// shape of a `ORDER BY embedding <=> $vec ASC LIMIT 1` query). Returns the
/// closest id if its distance is within threshold, else nil.
func canonicalIDFromNeighbors(
    _ neighbors: [(id: UUID, distance: Double)],
    threshold: Double = DUP_DISTANCE_THRESHOLD
) -> UUID? {
    guard let first = neighbors.first else { return nil }
    return first.distance <= threshold ? first.id : nil
}
