import Foundation
import Supabase

/// Singleton holding the supabase-swift SDK client. Used by both iOS and
/// watchOS targets — the SDK supports both. Replaces the hand-rolled
/// `SupabaseClient`, `SupabaseSync`, and per-platform auth refresh logic.
///
/// One client per process. Auth state, session refresh, retry, and Realtime
/// connection lifecycle are all handled by the SDK internally.
final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: Supabase.SupabaseClient

    private init() {
        let url = URL(string: "https://oumnicnvayqrbfbljgyl.supabase.co")!
        let key = "sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi"
        self.client = Supabase.SupabaseClient(supabaseURL: url, supabaseKey: key)
    }

    // Convenience accessors — same shape across both targets.
    var auth: AuthClient { client.auth }
    var storage: SupabaseStorageClient { client.storage }
    var realtime: RealtimeClientV2 { client.realtimeV2 }

    /// Postgrest query builder for a table. e.g. `manager.from("rounds").select()`
    func from(_ table: String) -> PostgrestQueryBuilder { client.from(table) }
}
