use alloy_primitives::U256;

pub fn gas_shortfall(required_prefund: U256, entry_point_deposit: U256) -> U256 {
    required_prefund.saturating_sub(entry_point_deposit)
}

pub fn minimum_account_balance(
    call_value: U256,
    required_prefund: U256,
    entry_point_deposit: U256,
) -> U256 {
    call_value + gas_shortfall(required_prefund, entry_point_deposit)
}

pub fn displayed_topup_minimum(minimum: U256) -> U256 {
    ceil_div(minimum * U256::from(12_u64), U256::from(10_u64))
}

pub fn reclaimable_entry_point_deposit(
    entry_point_deposit: U256,
    withdraw_required_prefund: U256,
    safety_margin: U256,
) -> U256 {
    entry_point_deposit.saturating_sub(withdraw_required_prefund + safety_margin)
}

fn ceil_div(numerator: U256, denominator: U256) -> U256 {
    if numerator.is_zero() {
        return U256::ZERO;
    }
    ((numerator - U256::from(1_u64)) / denominator) + U256::from(1_u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minimum_account_balance_adds_call_value_and_gas_shortfall() {
        assert_eq!(
            minimum_account_balance(U256::from(7), U256::from(10), U256::from(3)),
            U256::from(14)
        );
        assert_eq!(
            minimum_account_balance(U256::from(7), U256::from(10), U256::from(10)),
            U256::from(7)
        );
        assert_eq!(
            minimum_account_balance(U256::from(7), U256::from(10), U256::from(12)),
            U256::from(7)
        );
    }

    #[test]
    fn displayed_topup_minimum_adds_twenty_percent_rounding_up() {
        assert_eq!(displayed_topup_minimum(U256::ZERO), U256::ZERO);
        assert_eq!(displayed_topup_minimum(U256::from(1)), U256::from(2));
        assert_eq!(displayed_topup_minimum(U256::from(10)), U256::from(12));
        assert_eq!(displayed_topup_minimum(U256::from(11)), U256::from(14));
    }

    #[test]
    fn reclaimable_entry_point_deposit_leaves_prefund_and_margin() {
        assert_eq!(
            reclaimable_entry_point_deposit(U256::from(100), U256::from(30), U256::from(5)),
            U256::from(65)
        );
        assert_eq!(
            reclaimable_entry_point_deposit(U256::from(35), U256::from(30), U256::from(5)),
            U256::ZERO
        );
        assert_eq!(
            reclaimable_entry_point_deposit(U256::from(34), U256::from(30), U256::from(5)),
            U256::ZERO
        );
    }
}
