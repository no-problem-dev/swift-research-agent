import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - SearchResilienceConfiguration

/// Settings for the cache, rate limit, circuit breaker and retries around a search provider.
///
/// The defaults suit one unattended worker on a metered search API: one request per second, one
/// retry, and the breaker opening after five failures.
public struct SearchResilienceConfiguration: Sendable {
    /// Requests per second the limiter allows, which is also the bucket size (minimum one token).
    public let maxRequestsPerSecond: Double

    /// Consecutive failures that open the breaker. Retries count individually, so a single search
    /// with `maxRetries: 1` can contribute two.
    public let failureThreshold: Int

    /// Seconds an open breaker waits before going half-open, where calls pass again until one fails.
    public let resetTimeout: TimeInterval

    /// Seconds a cached result set stays valid. Expired entries still occupy a slot until evicted.
    public let cacheTTL: TimeInterval

    /// Cache capacity; reaching it evicts the least recently used entry.
    public let maxCacheEntries: Int

    /// Retries after the first attempt fails, so `1` means two attempts. Backoff starts at 500 ms
    /// and doubles.
    public let maxRetries: Int

    /// One request per second, one retry, breaker at five failures, 100 entries cached for 5 minutes.
    public static let `default` = SearchResilienceConfiguration(
        maxRequestsPerSecond: 1.0,
        failureThreshold: 5,
        resetTimeout: 60,
        cacheTTL: 300,
        maxCacheEntries: 100,
        maxRetries: 1
    )

    /// Creates a resilience configuration.
    ///
    /// - Parameters:
    ///   - maxRequestsPerSecond: Requests per second allowed (default: 1.0).
    ///   - failureThreshold: Consecutive failures that open the breaker (default: 5).
    ///   - resetTimeout: Seconds the breaker stays open (default: 60).
    ///   - cacheTTL: Seconds a cached result set stays valid (default: 300).
    ///   - maxCacheEntries: Cache capacity (default: 100).
    ///   - maxRetries: Retries after the first failed attempt (default: 1).
    public init(
        maxRequestsPerSecond: Double = 1.0,
        failureThreshold: Int = 5,
        resetTimeout: TimeInterval = 60,
        cacheTTL: TimeInterval = 300,
        maxCacheEntries: Int = 100,
        maxRetries: Int = 1
    ) {
        self.maxRequestsPerSecond = maxRequestsPerSecond
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
        self.cacheTTL = cacheTTL
        self.maxCacheEntries = maxCacheEntries
        self.maxRetries = maxRetries
    }
}

// MARK: - RateLimiter

/// Token bucket that paces calls to a search API.
public actor RateLimiter {
    private let maxTokens: Double
    private let refillRate: Double // tokens per second
    private var tokens: Double
    private var lastRefill: ContinuousClock.Instant

    /// Creates a limiter with a full bucket.
    ///
    /// - Parameter maxRequestsPerSecond: Refill rate. The bucket holds this many tokens, but never
    ///   fewer than one, so a rate below 1.0 still allows a single immediate call.
    public init(maxRequestsPerSecond: Double) {
        self.maxTokens = max(maxRequestsPerSecond, 1.0)
        self.refillRate = maxRequestsPerSecond
        self.tokens = maxTokens
        self.lastRefill = .now
    }

    /// Waits until a token is available, then spends it.
    ///
    /// - Throws: `CancellationError` when the task is cancelled, whether it was already cancelled
    ///   on entry or is cancelled while waiting. Nothing is spent and the caller stops, rather
    ///   than going on to make the request the limiter was holding back.
    public func acquire() async throws {
        try Task.checkCancellation()
        refillTokens()

        if tokens >= 1.0 {
            tokens -= 1.0
            return
        }

        // Wait for token to become available
        let waitTime = (1.0 - tokens) / refillRate
        try await Task.sleep(for: .milliseconds(Int(waitTime * 1000)))
        refillTokens()
        tokens = max(tokens - 1.0, 0)
    }

    private func refillTokens() {
        let now = ContinuousClock.Instant.now
        let elapsed = now - lastRefill
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(maxTokens, tokens + elapsedSeconds * refillRate)
        lastRefill = now
    }
}

// MARK: - CircuitBreaker

/// Stops calling a provider that keeps failing, and lets it back in after a cooldown.
public actor CircuitBreaker {
    /// Whether calls are passing, blocked, or passing again on trial after a cooldown.
    public enum State: Sendable {
        case closed
        case open
        case halfOpen
    }

    private let failureThreshold: Int
    private let resetTimeout: TimeInterval
    private var failureCount: Int = 0
    private var lastFailureTime: ContinuousClock.Instant?
    private(set) public var state: State = .closed

    /// Creates a closed breaker.
    ///
    /// - Parameters:
    ///   - failureThreshold: Consecutive failures that open it.
    ///   - resetTimeout: Seconds to stay open before going half-open.
    public init(failureThreshold: Int, resetTimeout: TimeInterval) {
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
    }

    /// Asks whether a call may go out, moving an open breaker to half-open once it has cooled down.
    ///
    /// Half-open lets every call through, not just one probe, and a single failure there opens the
    /// breaker again because the failure count is cleared only by a success.
    ///
    /// - Returns: `false` only while the breaker is open and still cooling down.
    public func requestExecution() -> Bool {
        switch state {
        case .closed:
            return true
        case .halfOpen:
            return true
        case .open:
            guard let lastFailure = lastFailureTime else { return true }
            let elapsed = ContinuousClock.Instant.now - lastFailure
            let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            guard elapsedSeconds >= resetTimeout else { return false }
            state = .halfOpen
            return true
        }
    }

    /// Clears the failure count and closes the breaker.
    public func recordSuccess() {
        failureCount = 0
        state = .closed
    }

    /// Counts a failure, opening the breaker once the threshold is reached.
    public func recordFailure() {
        failureCount += 1
        lastFailureTime = .now
        if failureCount >= failureThreshold {
            state = .open
        }
    }
}

// MARK: - SearchResultCache

/// Bounded LRU cache of search results, with a time-to-live.
///
/// Keyed by query and `maxResults` together, so asking for a different number of results misses.
public actor SearchResultCache {
    private struct CacheEntry {
        let results: [WebSearchResult]
        let timestamp: ContinuousClock.Instant
    }

    private struct CacheKey: Hashable {
        let query: String
        let maxResults: Int
    }

    private let ttl: TimeInterval
    private let maxEntries: Int
    private var cache: [CacheKey: CacheEntry] = [:]
    private var accessOrder: [CacheKey] = []

    /// Creates an empty cache.
    ///
    /// - Parameters:
    ///   - ttl: Seconds an entry stays valid.
    ///   - maxEntries: Capacity; reaching it evicts the least recently used entry.
    public init(ttl: TimeInterval, maxEntries: Int) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    /// Looks up a cached result set.
    ///
    /// An expired entry is reported as a miss but stays in the cache until eviction reaches it, so
    /// it keeps occupying capacity.
    ///
    /// - Returns: `nil` when nothing was cached for this query and result count, or when what was
    ///   cached is past its time-to-live.
    public func get(query: String, maxResults: Int) -> [WebSearchResult]? {
        let key = CacheKey(query: query, maxResults: maxResults)
        guard let entry = cache[key] else { return nil }

        let elapsed = ContinuousClock.Instant.now - entry.timestamp
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if elapsedSeconds > ttl {
            return nil // Expired
        }

        // Move to end of access order (LRU)
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
            accessOrder.append(key)
        }

        return entry.results
    }

    /// Stores results and marks them most recently used, evicting the oldest entry when full.
    public func set(_ results: [WebSearchResult], query: String, maxResults: Int) {
        let key = CacheKey(query: query, maxResults: maxResults)

        // Evict LRU if at capacity
        if cache[key] == nil && cache.count >= maxEntries {
            evictOldest()
        }

        cache[key] = CacheEntry(results: results, timestamp: .now)

        // Update access order
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(key)
    }

    public func clear() {
        cache.removeAll()
        accessOrder.removeAll()
    }

    /// Number of stored entries, including any that are past their time-to-live.
    public var count: Int {
        cache.count
    }

    private func evictOldest() {
        guard let oldest = accessOrder.first else { return }
        accessOrder.removeFirst()
        cache.removeValue(forKey: oldest)
    }
}

// MARK: - ResilientSearchProvider

/// Wraps a search provider with a cache, a rate limit, a circuit breaker and retries.
///
/// The cache is consulted before the breaker, so repeated queries keep answering even while the
/// breaker is open.
public final class ResilientSearchProvider: WebSearchProvider, Sendable {
    private let provider: any WebSearchProvider
    private let rateLimiter: RateLimiter
    private let circuitBreaker: CircuitBreaker
    private let cache: SearchResultCache
    private let maxRetries: Int

    /// Wraps a provider in the resilience layers.
    ///
    /// - Parameters:
    ///   - provider: Provider to wrap. It sees only the calls that get past the cache and the breaker.
    ///   - configuration: Cache, rate limit, breaker and retry settings.
    public init(provider: any WebSearchProvider, configuration: SearchResilienceConfiguration = .default) {
        self.provider = provider
        self.rateLimiter = RateLimiter(maxRequestsPerSecond: configuration.maxRequestsPerSecond)
        self.circuitBreaker = CircuitBreaker(
            failureThreshold: configuration.failureThreshold,
            resetTimeout: configuration.resetTimeout
        )
        self.cache = SearchResultCache(ttl: configuration.cacheTTL, maxEntries: configuration.maxCacheEntries)
        self.maxRetries = configuration.maxRetries
    }

    /// Runs a query through the cache, the breaker, the rate limit and the retries.
    ///
    /// Only successful, non-cached calls are stored, and every failed attempt — retries included —
    /// counts toward opening the breaker. Cancellation is neither retried nor counted: it stops
    /// the search where it stands.
    ///
    /// - Returns: The cached results when a valid entry exists, otherwise the provider's.
    /// - Throws: `WebSearchError.circuitBreakerOpen` while the breaker is open and cooling down,
    ///   `CancellationError` if the task is cancelled, otherwise the error from the last attempt.
    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        // 1. Check cache
        if let cached = await cache.get(query: query, maxResults: maxResults) {
            return cached
        }

        // 2. Request execution from circuit breaker (includes state transition)
        let canExecute = await circuitBreaker.requestExecution()
        guard canExecute else {
            throw WebSearchError.circuitBreakerOpen
        }

        // 3. Rate limiting + retry
        var lastError: Error?
        for attempt in 0...maxRetries {
            if attempt > 0 {
                // Exponential backoff for retries
                try await Task.sleep(for: .milliseconds(500 * (1 << (attempt - 1))))
            }

            try await rateLimiter.acquire()

            do {
                let results = try await provider.search(query: query, maxResults: maxResults)
                await circuitBreaker.recordSuccess()
                await cache.set(results, query: query, maxResults: maxResults)
                return results
            } catch is CancellationError {
                // The caller stopped waiting. Retrying would fire the request anyway, and counting
                // it as a provider failure would open the breaker over a call nobody wanted.
                throw CancellationError()
            } catch {
                lastError = error
                await circuitBreaker.recordFailure()
            }
        }

        throw lastError ?? WebSearchError.invalidResponse
    }
}
