import Foundation

/// Cosine distance threshold below which two items count as the same story.
/// Calibration with nomic-embed-text on news title+lead pairs:
///   0.00–0.05  same article restated
///   0.06–0.14  same story, different outlets / paraphrased headline + different lede
///   0.15–0.30  same topic, different angle (e.g. "AI funding boom" + "AI bubble fears")
///   0.30+      unrelated
///
/// Bumped from 0.08 to 0.15 after real-user feedback caught two
/// obvious-same-story pairs that weren't clustering: NYT vs NPR on
/// the Musk-Altman court case, and Ars vs NYT on the China-Meta-Manus
/// regulatory block. Both pairs read as paraphrased same-story to a
/// human; 0.08 was treating them as different stories. 0.15 is at the
/// edge of the same-story / same-topic boundary — slight risk of
/// collapsing two angles on a hot topic, but worth it for the much
/// cleaner feed when wire stories propagate across outlets.
let DUP_DISTANCE_THRESHOLD: Double = 0.15

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
