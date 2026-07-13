use std::collections::BTreeMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use alloy_primitives::{Address, U256};
use wallet_node_api::Method;

use crate::config::RateLimitConfig;

const SENDER_QUOTA_BUCKET_TTL: Duration = Duration::from_secs(24 * 60 * 60);

#[derive(Default)]
pub struct RateLimiter {
    buckets: Mutex<BTreeMap<String, Bucket>>,
}

#[derive(Default)]
pub struct PerSenderRateLimiter {
    buckets: Mutex<BTreeMap<SenderQuotaKey, SenderQuotaBucket>>,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct SenderQuotaKey {
    chain_id: u64,
    sender: [u8; 20],
}

#[derive(Clone, Copy, Debug)]
struct SenderQuotaBucket {
    user_ops: Bucket,
    gas_wei: Bucket,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SenderQuotaDecision {
    pub allowed: bool,
    pub reason: Option<&'static str>,
    pub retry_after_secs: f64,
}

#[derive(Clone, Copy, Debug)]
pub struct SenderQuotaConfig {
    pub max_user_ops_per_minute: u32,
    pub max_gas_wei_per_hour: U256,
}

impl PerSenderRateLimiter {
    pub fn check(
        &self,
        chain_id: u64,
        sender: Address,
        gas_wei: U256,
        config: SenderQuotaConfig,
    ) -> SenderQuotaDecision {
        let user_ops_enabled = config.max_user_ops_per_minute > 0;
        let gas_enabled = config.max_gas_wei_per_hour > U256::ZERO;
        if !user_ops_enabled && !gas_enabled {
            return SenderQuotaDecision {
                allowed: true,
                reason: None,
                retry_after_secs: 0.0,
            };
        }

        let now = Instant::now();
        let key = SenderQuotaKey {
            chain_id,
            sender: sender.into_array(),
        };
        let mut buckets = self
            .buckets
            .lock()
            .expect("per-sender rate limiter mutex should not be poisoned");
        evict_idle_sender_buckets(&mut buckets, now);
        let bucket = buckets.entry(key).or_insert_with(|| SenderQuotaBucket {
            user_ops: Bucket {
                tokens: config.max_user_ops_per_minute as f64,
                last_refill: now,
            },
            gas_wei: Bucket {
                tokens: u256_to_f64(config.max_gas_wei_per_hour),
                last_refill: now,
            },
        });

        if user_ops_enabled {
            refill(
                &mut bucket.user_ops,
                config.max_user_ops_per_minute as f64,
                config.max_user_ops_per_minute as f64 / 60.0,
                now,
            );
            if bucket.user_ops.tokens < 1.0 {
                return SenderQuotaDecision {
                    allowed: false,
                    reason: Some("sender_user_ops_per_minute_exceeded"),
                    retry_after_secs: (1.0 - bucket.user_ops.tokens)
                        / (config.max_user_ops_per_minute as f64 / 60.0),
                };
            }
        }

        let gas_cost = u256_to_f64(gas_wei);
        if gas_enabled {
            let gas_limit = u256_to_f64(config.max_gas_wei_per_hour);
            let refill_per_sec = gas_limit / 3600.0;
            refill(&mut bucket.gas_wei, gas_limit, refill_per_sec, now);
            if bucket.gas_wei.tokens < gas_cost {
                return SenderQuotaDecision {
                    allowed: false,
                    reason: Some("sender_gas_wei_per_hour_exceeded"),
                    retry_after_secs: (gas_cost - bucket.gas_wei.tokens) / refill_per_sec,
                };
            }
        }

        if user_ops_enabled {
            bucket.user_ops.tokens -= 1.0;
        }
        if gas_enabled {
            bucket.gas_wei.tokens -= gas_cost;
        }

        SenderQuotaDecision {
            allowed: true,
            reason: None,
            retry_after_secs: 0.0,
        }
    }
}

fn evict_idle_sender_buckets(
    buckets: &mut BTreeMap<SenderQuotaKey, SenderQuotaBucket>,
    now: Instant,
) {
    buckets.retain(|_, bucket| {
        let last_seen = bucket.user_ops.last_refill.max(bucket.gas_wei.last_refill);
        now.duration_since(last_seen) <= SENDER_QUOTA_BUCKET_TTL
    });
}

fn refill(bucket: &mut Bucket, burst: f64, refill_per_sec: f64, now: Instant) {
    let elapsed = now.duration_since(bucket.last_refill).as_secs_f64();
    bucket.tokens = (bucket.tokens + elapsed * refill_per_sec).min(burst);
    bucket.last_refill = now;
}

fn u256_to_f64(value: U256) -> f64 {
    let parsed = value.to_string().parse::<f64>().unwrap_or(f64::MAX);
    if parsed.is_finite() {
        parsed
    } else {
        f64::MAX
    }
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

        refill(bucket, limit.burst as f64, limit.refill_per_sec, now);

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
        Method::LocalWalletSendUserOperation => Some("localwallet_sendUserOperation"),
        Method::LocalWalletEstimateUserOperationGas => Some("localwallet_estimateUserOperationGas"),
        Method::EthGetBalance
        | Method::EthGetCode
        | Method::EthGetTransactionCount
        | Method::EthCall
        | Method::EthGetTransactionReceipt
        | Method::EthGetBlockByNumber
        | Method::LocalWalletResolveName
        | Method::LocalWalletQuoteSwap
        | Method::LocalWalletGetUserOperationStatus => Some("read_methods_total"),
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
            "localwallet_sendUserOperation".to_string(),
            RateLimitConfig {
                refill_per_sec: 0.1,
                burst: 1,
            },
        )]);

        assert!(
            limiter
                .check(Method::LocalWalletSendUserOperation, &config)
                .allowed
        );
        let second = limiter.check(Method::LocalWalletSendUserOperation, &config);
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

    #[test]
    fn per_sender_bucket_blocks_after_threshold() {
        let limiter = PerSenderRateLimiter::default();
        let sender = Address::repeat_byte(0x11);
        let config = SenderQuotaConfig {
            max_user_ops_per_minute: 1,
            max_gas_wei_per_hour: U256::ZERO,
        };

        assert!(limiter.check(1, sender, U256::from(1), config).allowed);
        let blocked = limiter.check(1, sender, U256::from(1), config);
        assert!(!blocked.allowed);
        assert_eq!(blocked.reason, Some("sender_user_ops_per_minute_exceeded"));
        assert!(blocked.retry_after_secs > 0.0);
    }

    #[test]
    fn per_sender_bucket_is_independent_per_sender() {
        let limiter = PerSenderRateLimiter::default();
        let config = SenderQuotaConfig {
            max_user_ops_per_minute: 1,
            max_gas_wei_per_hour: U256::ZERO,
        };

        assert!(
            limiter
                .check(1, Address::repeat_byte(0x11), U256::ZERO, config)
                .allowed
        );
        assert!(
            limiter
                .check(1, Address::repeat_byte(0x22), U256::ZERO, config)
                .allowed
        );
    }

    #[test]
    fn per_sender_gas_bucket_blocks_after_threshold() {
        let limiter = PerSenderRateLimiter::default();
        let config = SenderQuotaConfig {
            max_user_ops_per_minute: 0,
            max_gas_wei_per_hour: U256::from(10),
        };

        assert!(
            limiter
                .check(1, Address::repeat_byte(0x11), U256::from(6), config)
                .allowed
        );
        let blocked = limiter.check(1, Address::repeat_byte(0x11), U256::from(6), config);
        assert!(!blocked.allowed);
        assert_eq!(blocked.reason, Some("sender_gas_wei_per_hour_exceeded"));
    }

    #[test]
    fn u256_to_f64_saturates_to_finite_value() {
        assert_eq!(u256_to_f64(U256::from(42)), 42.0);

        let saturated = u256_to_f64(U256::MAX);
        assert!(saturated.is_finite());
        assert!(saturated <= f64::MAX);
    }

    #[test]
    fn per_sender_bucket_evicts_idle_entries() {
        let limiter = PerSenderRateLimiter::default();
        let now = Instant::now();
        {
            let mut buckets = limiter.buckets.lock().unwrap();
            buckets.insert(
                SenderQuotaKey {
                    chain_id: 1,
                    sender: Address::repeat_byte(0x11).into_array(),
                },
                SenderQuotaBucket {
                    user_ops: Bucket {
                        tokens: 1.0,
                        last_refill: now - Duration::from_secs(25 * 60 * 60),
                    },
                    gas_wei: Bucket {
                        tokens: 1.0,
                        last_refill: now - Duration::from_secs(25 * 60 * 60),
                    },
                },
            );
            buckets.insert(
                SenderQuotaKey {
                    chain_id: 1,
                    sender: Address::repeat_byte(0x22).into_array(),
                },
                SenderQuotaBucket {
                    user_ops: Bucket {
                        tokens: 1.0,
                        last_refill: now,
                    },
                    gas_wei: Bucket {
                        tokens: 1.0,
                        last_refill: now,
                    },
                },
            );
        }
        let config = SenderQuotaConfig {
            max_user_ops_per_minute: 10,
            max_gas_wei_per_hour: U256::ZERO,
        };

        assert!(
            limiter
                .check(1, Address::repeat_byte(0x33), U256::ZERO, config)
                .allowed
        );

        let buckets = limiter.buckets.lock().unwrap();
        assert!(!buckets.contains_key(&SenderQuotaKey {
            chain_id: 1,
            sender: Address::repeat_byte(0x11).into_array(),
        }));
        assert!(buckets.contains_key(&SenderQuotaKey {
            chain_id: 1,
            sender: Address::repeat_byte(0x22).into_array(),
        }));
        assert!(buckets.contains_key(&SenderQuotaKey {
            chain_id: 1,
            sender: Address::repeat_byte(0x33).into_array(),
        }));
    }
}
