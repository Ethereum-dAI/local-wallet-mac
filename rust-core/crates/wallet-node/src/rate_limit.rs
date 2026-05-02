use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::Instant;

use wallet_node_api::Method;

use crate::config::RateLimitConfig;

#[derive(Default)]
pub struct RateLimiter {
    buckets: Mutex<BTreeMap<String, Bucket>>,
}

#[derive(Clone, Copy, Debug)]
struct Bucket {
    tokens: f64,
    last_refill: Instant,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RateLimitDecision {
    pub allowed: bool,
    pub retry_after_secs: f64,
}

impl RateLimiter {
    pub fn check(
        &self,
        method: Method,
        config: &BTreeMap<String, RateLimitConfig>,
    ) -> RateLimitDecision {
        let Some(key) = rate_limit_key(&method) else {
            return RateLimitDecision {
                allowed: true,
                retry_after_secs: 0.0,
            };
        };
        let Some(limit) = config.get(key) else {
            return RateLimitDecision {
                allowed: true,
                retry_after_secs: 0.0,
            };
        };
        if limit.burst == 0 || limit.refill_per_sec <= 0.0 {
            return RateLimitDecision {
                allowed: false,
                retry_after_secs: f64::INFINITY,
            };
        }

        let now = Instant::now();
        let mut buckets = self
            .buckets
            .lock()
            .expect("rate limiter mutex should not be poisoned");
        let bucket = buckets.entry(key.to_owned()).or_insert(Bucket {
            tokens: limit.burst as f64,
            last_refill: now,
        });

        let elapsed = now.duration_since(bucket.last_refill).as_secs_f64();
        bucket.tokens = (bucket.tokens + elapsed * limit.refill_per_sec).min(limit.burst as f64);
        bucket.last_refill = now;

        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0;
            RateLimitDecision {
                allowed: true,
                retry_after_secs: 0.0,
            }
        } else {
            RateLimitDecision {
                allowed: false,
                retry_after_secs: (1.0 - bucket.tokens) / limit.refill_per_sec,
            }
        }
    }
}

fn rate_limit_key(method: &Method) -> Option<&'static str> {
    match method {
        Method::EthSendUserOperation => Some("eth_sendUserOperation"),
        Method::EthEstimateUserOperationGas => Some("eth_estimateUserOperationGas"),
        Method::EthGetBalance
        | Method::EthGetCode
        | Method::EthGetTransactionCount
        | Method::EthCall
        | Method::EthGetTransactionReceipt
        | Method::EthGetBlockByNumber => Some("read_methods_total"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn burst_is_enforced_per_bucket() {
        let limiter = RateLimiter::default();
        let config = BTreeMap::from([(
            "eth_sendUserOperation".to_string(),
            RateLimitConfig {
                refill_per_sec: 0.1,
                burst: 1,
            },
        )]);

        assert!(limiter.check(Method::EthSendUserOperation, &config).allowed);
        let second = limiter.check(Method::EthSendUserOperation, &config);
        assert!(!second.allowed);
        assert!(second.retry_after_secs > 0.0);
    }

    #[test]
    fn read_methods_share_total_bucket() {
        let limiter = RateLimiter::default();
        let config = BTreeMap::from([(
            "read_methods_total".to_string(),
            RateLimitConfig {
                refill_per_sec: 0.1,
                burst: 1,
            },
        )]);

        assert!(limiter.check(Method::EthGetBalance, &config).allowed);
        assert!(!limiter.check(Method::EthGetCode, &config).allowed);
    }
}
