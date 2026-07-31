const std = @import("std");

pub const max_buckets = 4096;
const burst_tokens: f64 = 30;
const tokens_per_second: f64 = 2;
const expiry_seconds: i64 = 10 * 60;

const Bucket = struct {
    key: u64 = 0,
    tokens: f64 = 0,
    updated_at: i64 = 0,
    occupied: bool = false,
};

pub const Limiter = struct {
    buckets: [max_buckets]Bucket = @splat(.{}),

    pub fn allow(self: *Limiter, key: u64, now: i64) bool {
        var reusable: ?*Bucket = null;
        for (&self.buckets) |*bucket| {
            if (bucket.occupied and bucket.key == key) {
                if (now < bucket.updated_at or now - bucket.updated_at >= expiry_seconds) {
                    bucket.tokens = burst_tokens - 1;
                    bucket.updated_at = now;
                    return true;
                }
                const elapsed: f64 = @floatFromInt(now - bucket.updated_at);
                bucket.tokens = @min(
                    burst_tokens,
                    bucket.tokens + elapsed * tokens_per_second,
                );
                bucket.updated_at = now;
                if (bucket.tokens < 1) return false;
                bucket.tokens -= 1;
                return true;
            }
            if (reusable == null and
                (!bucket.occupied or now < bucket.updated_at or
                    now - bucket.updated_at >= expiry_seconds))
            {
                reusable = bucket;
            }
        }
        const bucket = reusable orelse return false;
        bucket.* = .{
            .key = key,
            .tokens = burst_tokens - 1,
            .updated_at = now,
            .occupied = true,
        };
        return true;
    }
};
