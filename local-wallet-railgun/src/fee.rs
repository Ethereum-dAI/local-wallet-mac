//! Pure amount arithmetic for a paymaster-sponsored RAILGUN exit. No I/O, no chain access.
//!
//! Two deductions hit the shielded balance: the note value drained for the unshield, and a
//! separate in-pool WETH fee note paid to the privacy paymaster. Only the first is known
//! before proving, which is why `max_unshieldable` reserves headroom for the second.

/// Basis-point denominator for the RAILGUN treasury unshield fee.
const BPS_DENOMINATOR: u128 = 10_000;

/// Under-claim margin, in wei, applied to the amount we unwrap and forward.
///
/// Its only job is to guarantee `WETH.withdraw` can never revert. The exact rounding in
/// RailgunSmartWallet's `getFee` is NOT verified — `delivered_lower_bound` is deliberately a
/// lower bound, so any mismatch leaves extra dust rather than reverting an op whose unshield
/// has already executed during paymaster validation.
pub const DELIVERY_EPSILON_WEI: u128 = 1000;

/// Conservative 4337 gas units for a sponsored RAILGUN unshield, used ONLY to reserve
/// headroom for the fee note. The SDK still estimates the real fee at broadcast time.
///
/// Seeded from kohaku-cli `src/utils/railgun-unshield-max.ts:12-20`. These are a starting
/// upper bound, not a measurement: on the pinned rev the paymaster performs the on-chain
/// Groth16 verification during *validation*, so cost concentrates in
/// `paymaster_verification_gas_limit`. Recalibrate from the fork fixture and the live run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GasUnits {
    pub pre_verification_gas: u128,
    pub verification_gas_limit: u128,
    pub call_gas_limit: u128,
    /// Extra call gas for the WETH → ETH unwrap + forward tail calls.
    pub native_unwrap_call_gas: u128,
    pub paymaster_verification_gas_limit: u128,
    pub paymaster_post_op_gas_limit: u128,
}

pub const RAILGUN_UNSHIELD_GAS_UNITS: GasUnits = GasUnits {
    pre_verification_gas: 100_000,
    verification_gas_limit: 150_000,
    call_gas_limit: 2_500_000,
    native_unwrap_call_gas: 80_000,
    paymaster_verification_gas_limit: 400_000,
    paymaster_post_op_gas_limit: 120_000,
};

/// Safety margin on the reserve, as a percentage. Matches kohaku-cli's 1.2x.
const RESERVE_MARGIN_NUM: u128 = 12;
const RESERVE_MARGIN_DEN: u128 = 10;

/// A LOWER BOUND on the wei RailgunSmartWallet delivers when `value` leaves the pool.
///
/// Uses kohaku-cli's formula (`railgun-unshield-max.ts:68`): `floor(value * (10000 - bps) /
/// 10000)`. If the contract instead applies an "inclusive" fee
/// (`base = value * 10000 / 10025`) it delivers slightly MORE, which is safe — the surplus
/// becomes dust in the single-use sender. The fork fixture asserts the real figure.
pub fn delivered_lower_bound(value: u128, fee_bps: u16) -> u128 {
    let bps = fee_bps as u128;
    if bps >= BPS_DENOMINATOR {
        return 0;
    }
    value / BPS_DENOMINATOR * (BPS_DENOMINATOR - bps)
        + (value % BPS_DENOMINATOR) * (BPS_DENOMINATOR - bps) / BPS_DENOMINATOR
}

/// Wei to hold back for the paymaster's fee note: total gas x price x 1.2.
pub fn gas_reserve_wei(units: &GasUnits, max_fee_per_gas: u128) -> u128 {
    let total_gas = units.pre_verification_gas
        + units.verification_gas_limit
        + units.call_gas_limit
        + units.native_unwrap_call_gas
        + units.paymaster_verification_gas_limit
        + units.paymaster_post_op_gas_limit;
    total_gas
        .saturating_mul(max_fee_per_gas)
        .saturating_mul(RESERVE_MARGIN_NUM)
        / RESERVE_MARGIN_DEN
}

/// The two numbers the app needs. Because there is no gross-up, the user's requested
/// `amountWei` IS `max_value` (what leaves the pool); `receivable_at_max` is for the
/// "you will receive" breakdown. Conflating them would reject valid requests or accept
/// ones that cannot fit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MaxUnshieldable {
    pub max_value: u128,
    pub receivable_at_max: u128,
}

pub fn max_unshieldable(balance: u128, fee_bps: u16, reserve: u128) -> MaxUnshieldable {
    let max_value = balance.saturating_sub(reserve);
    let receivable_at_max =
        delivered_lower_bound(max_value, fee_bps).saturating_sub(DELIVERY_EPSILON_WEI);
    MaxUnshieldable {
        max_value,
        receivable_at_max,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delivered_is_floor_of_9975_over_10000() {
        // 5000 * 9975 / 10000 = 4987.5 → floor 4987 (conservative: never over-predict).
        assert_eq!(delivered_lower_bound(5_000, 25), 4_987);
        // Exact multiple: 10_000 * 9975 / 10000 = 9975, no rounding.
        assert_eq!(delivered_lower_bound(10_000, 25), 9_975);
        assert_eq!(delivered_lower_bound(0, 25), 0);
    }

    #[test]
    fn delivered_never_exceeds_value() {
        for v in [1u128, 2, 3, 999, 1_000_000_000_000_000_000] {
            assert!(delivered_lower_bound(v, 25) <= v, "value {v}");
        }
    }

    #[test]
    fn delivered_saturates_on_absurd_fee() {
        // A fee at or above 100% must yield zero, never underflow.
        assert_eq!(delivered_lower_bound(1_000, 10_000), 0);
        assert_eq!(delivered_lower_bound(1_000, 20_000), 0);
    }

    #[test]
    fn gas_reserve_applies_1_2x_margin_and_unwrap_gas() {
        let units = GasUnits {
            pre_verification_gas: 100,
            verification_gas_limit: 100,
            call_gas_limit: 100,
            native_unwrap_call_gas: 100,
            paymaster_verification_gas_limit: 100,
            paymaster_post_op_gas_limit: 100,
        };
        // 600 total gas * 10 wei/gas * 1.2 = 7200.
        assert_eq!(gas_reserve_wei(&units, 10), 7_200);
    }

    #[test]
    fn max_unshieldable_subtracts_reserve_then_fee() {
        // balance 20_000, reserve 10_000 → max_value 10_000;
        // receivable = floor(10_000 * 9975/10000) - 1000 = 9975 - 1000 = 8975.
        let m = max_unshieldable(20_000, 25, 10_000);
        assert_eq!(m.max_value, 10_000);
        assert_eq!(m.receivable_at_max, 8_975);
    }

    #[test]
    fn max_unshieldable_is_zero_when_reserve_exceeds_balance() {
        let m = max_unshieldable(5_000, 25, 10_000);
        assert_eq!(m.max_value, 0);
        assert_eq!(m.receivable_at_max, 0);
    }

    #[test]
    fn max_unshieldable_receivable_saturates_below_epsilon() {
        // max_value 100 → delivered 99, minus epsilon 1000 must not underflow.
        let m = max_unshieldable(1_100, 25, 1_000);
        assert_eq!(m.max_value, 100);
        assert_eq!(m.receivable_at_max, 0);
    }

    #[test]
    fn overflow_safe_form_matches_naive_form() {
        for v in [
            0u128,
            1,
            9_999,
            10_000,
            10_001,
            123_456_789,
            u64::MAX as u128,
        ] {
            let naive = v * 9_975 / 10_000;
            assert_eq!(delivered_lower_bound(v, 25), naive, "value {v}");
        }
    }
}
