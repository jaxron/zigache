/// Node represents an entry in the cache.
/// It contains the key-value pair, linked list pointers, expiration information,
/// and additional data specific to the caching algorithm.
pub fn Node(comptime K: type, comptime V: type, comptime T: type) type {
    return struct {
        key: K,
        value: V,

        /// Pointer to the next node in the linked list
        next: ?*Node(K, V, T) = null,
        // Pointer to the previous node in the linked list
        prev: ?*Node(K, V, T) = null,

        /// The expiry field stores the timestamp when this cache entry should expire, in seconds.
        /// It is of type `?i64`, where:
        /// - `null` indicates that the entry does not expire
        /// - A non-null value represents the expiration time as a Unix timestamp
        ///   (seconds since the Unix epoch)
        ///
        /// This field is used in TTL (Time-To-Live) operations to determine if an entry
        /// should be considered valid or if it should be removed from the cache.
        expiry: ?i64,

        /// Additional data specific to the caching algorithm (e.g., frequency counters, flags)
        data: T,
    };
}
