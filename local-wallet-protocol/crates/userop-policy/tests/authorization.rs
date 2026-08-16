use alloy_primitives::{Address, Bytes, FixedBytes, U256};
use wallet_signature::PackedUserOperation;
use wallet_userop_policy::{
    authorize_no_paymaster, checked_max_liability_no_paymaster, conservative_pre_verification_gas,
    encode_single_handle_ops, v1_owner_caps, v1_session_caps, validate_entrypoint_v07_width,
    AuthorizedGasPlan, GasAuthorizationCaps, GasAuthorizationInput, GasPolicyError, GasSchedule,
    ENTRY_POINT_V07_FIELD_MAX, V1_MAX_CALL_GAS_LIMIT, V1_MAX_FEE_PER_GAS_WEI,
    V1_MAX_PRE_VERIFICATION_GAS, V1_MAX_PRIORITY_FEE_PER_GAS_WEI, V1_MAX_VERIFICATION_GAS_LIMIT,
    V1_OWNER_MAX_LIABILITY_WEI, V1_SESSION_MAX_LIABILITY_WEI,
};

const FIXED_OVERHEAD: u64 = 35_000;
const PER_USER_OP_OVERHEAD: u64 = 18_300;
const SAFETY_NUMERATOR: u64 = 12_000;
const SAFETY_DENOMINATOR: u64 = 10_000;

fn input() -> GasAuthorizationInput {
    GasAuthorizationInput {
        sender: Address::from([0x11; 20]),
        nonce: U256::from(7),
        init_code: Bytes::new(),
        call_data: Bytes::from(vec![0x42; 96]),
        call_gas_limit: U256::from(125_000),
        verification_gas_limit: U256::from(250_000),
        max_fee_per_gas: U256::from(10_000_000_000_u64),
        max_priority_fee_per_gas: U256::from(1_000_000_000_u64),
        paymaster_and_data: Bytes::new(),
        signature_len: 480,
    }
}

fn permissive_caps() -> GasAuthorizationCaps {
    GasAuthorizationCaps {
        max_call_gas_limit: ENTRY_POINT_V07_FIELD_MAX,
        max_verification_gas_limit: ENTRY_POINT_V07_FIELD_MAX,
        max_pre_verification_gas: ENTRY_POINT_V07_FIELD_MAX,
        max_fee_per_gas: ENTRY_POINT_V07_FIELD_MAX,
        max_priority_fee_per_gas: ENTRY_POINT_V07_FIELD_MAX,
        max_liability: U256::MAX,
    }
}

fn pack_pair(high: U256, low: U256) -> FixedBytes<32> {
    let high = high.to_be_bytes::<32>();
    let low = low.to_be_bytes::<32>();
    let mut packed = [0_u8; 32];
    packed[..16].copy_from_slice(&high[16..]);
    packed[16..].copy_from_slice(&low[16..]);
    FixedBytes::from(packed)
}

fn packed_for_cost(input: &GasAuthorizationInput) -> PackedUserOperation {
    PackedUserOperation {
        sender: input.sender,
        nonce: input.nonce,
        init_code: input.init_code.clone(),
        call_data: input.call_data.clone(),
        account_gas_limits: pack_pair(input.verification_gas_limit, input.call_gas_limit),
        // Deliberately all-nonzero to avoid the circular calldata-cost undercount.
        pre_verification_gas: U256::MAX,
        gas_fees: pack_pair(input.max_priority_fee_per_gas, input.max_fee_per_gas),
        paymaster_and_data: input.paymaster_and_data.clone(),
    }
}

#[derive(Debug)]
struct ReferenceCost {
    legacy: U256,
    pectra_floor: U256,
    selected: U256,
    with_margin: U256,
}

fn reference_cost(input: &GasAuthorizationInput) -> ReferenceCost {
    let signature = vec![0xff; input.signature_len];
    let calldata = encode_single_handle_ops(
        &packed_for_cost(input),
        &signature,
        Address::from([0xff; 20]),
    );
    let zero = calldata.iter().filter(|byte| **byte == 0).count() as u64;
    let nonzero = calldata.len() as u64 - zero;
    let calldata_gas = U256::from(zero * 4 + nonzero * 16);
    let word_overhead = U256::from((calldata.len() as u64).div_ceil(32) * 4);
    let legacy = U256::from(FIXED_OVERHEAD)
        + U256::from(PER_USER_OP_OVERHEAD)
        + word_overhead
        + calldata_gas;
    let tokens = U256::from(zero + nonzero * 4);
    let pectra_floor = U256::from(21_000) + tokens * U256::from(10);
    let selected = legacy.max(pectra_floor);
    let numerator = selected * U256::from(SAFETY_NUMERATOR);
    let denominator = U256::from(SAFETY_DENOMINATOR);
    let with_margin =
        numerator / denominator + U256::from(u8::from(numerator % denominator != U256::ZERO));
    ReferenceCost {
        legacy,
        pectra_floor,
        selected,
        with_margin,
    }
}

fn assert_cap_boundary(
    mut exact: GasAuthorizationInput,
    caps: GasAuthorizationCaps,
    mutate_above: impl FnOnce(&mut GasAuthorizationInput),
    field: &'static str,
) {
    authorize_no_paymaster(&exact, &caps, GasSchedule::EthereumPectraSingleOpV07V1)
        .expect("value exactly at its cap must be accepted");
    mutate_above(&mut exact);
    assert_eq!(
        authorize_no_paymaster(&exact, &caps, GasSchedule::EthereumPectraSingleOpV07V1),
        Err(GasPolicyError::CapExceeded { field })
    );
}

#[test]
fn v1_caps_match_the_approved_product_policy() {
    let owner = v1_owner_caps();
    assert_eq!(owner.max_call_gas_limit, U256::from(V1_MAX_CALL_GAS_LIMIT));
    assert_eq!(
        owner.max_verification_gas_limit,
        U256::from(V1_MAX_VERIFICATION_GAS_LIMIT)
    );
    assert_eq!(
        owner.max_pre_verification_gas,
        U256::from(V1_MAX_PRE_VERIFICATION_GAS)
    );
    assert_eq!(owner.max_fee_per_gas, U256::from(V1_MAX_FEE_PER_GAS_WEI));
    assert_eq!(
        owner.max_priority_fee_per_gas,
        U256::from(V1_MAX_PRIORITY_FEE_PER_GAS_WEI)
    );
    assert_eq!(owner.max_liability, U256::from(V1_OWNER_MAX_LIABILITY_WEI));

    assert_eq!(
        v1_session_caps(U256::from(V1_OWNER_MAX_LIABILITY_WEI)).max_liability,
        U256::from(V1_SESSION_MAX_LIABILITY_WEI)
    );
    assert_eq!(
        v1_session_caps(U256::from(123_u64)).max_liability,
        U256::from(123_u64)
    );
}

#[test]
fn authorizes_and_packs_fields_in_entrypoint_order() {
    let input = input();
    let plan = authorize_no_paymaster(
        &input,
        &v1_owner_caps(),
        GasSchedule::EthereumPectraSingleOpV07V1,
    )
    .unwrap();

    assert_eq!(
        plan.account_gas_limits,
        pack_pair(input.verification_gas_limit, input.call_gas_limit)
    );
    assert_eq!(
        plan.gas_fees,
        pack_pair(input.max_priority_fee_per_gas, input.max_fee_per_gas)
    );
    assert_eq!(plan.signature_len, input.signature_len);
    assert_eq!(plan.policy_version, 1);
}

#[test]
fn every_configured_field_cap_accepts_exact_and_rejects_plus_one() {
    let base = input();

    let mut caps = permissive_caps();
    caps.max_call_gas_limit = base.call_gas_limit;
    assert_cap_boundary(
        base.clone(),
        caps,
        |op| op.call_gas_limit += U256::from(1),
        "callGasLimit",
    );

    let mut caps = permissive_caps();
    caps.max_verification_gas_limit = base.verification_gas_limit;
    assert_cap_boundary(
        base.clone(),
        caps,
        |op| op.verification_gas_limit += U256::from(1),
        "verificationGasLimit",
    );

    let mut caps = permissive_caps();
    caps.max_fee_per_gas = base.max_fee_per_gas;
    assert_cap_boundary(
        base.clone(),
        caps,
        |op| op.max_fee_per_gas += U256::from(1),
        "maxFeePerGas",
    );

    let mut caps = permissive_caps();
    caps.max_priority_fee_per_gas = base.max_priority_fee_per_gas;
    assert_cap_boundary(
        base.clone(),
        caps,
        |op| op.max_priority_fee_per_gas += U256::from(1),
        "maxPriorityFeePerGas",
    );

    let pvg =
        conservative_pre_verification_gas(&base, GasSchedule::EthereumPectraSingleOpV07V1).unwrap();
    let mut exact_caps = permissive_caps();
    exact_caps.max_pre_verification_gas = pvg;
    authorize_no_paymaster(&base, &exact_caps, GasSchedule::EthereumPectraSingleOpV07V1).unwrap();
    exact_caps.max_pre_verification_gas = pvg - U256::from(1);
    assert_eq!(
        authorize_no_paymaster(&base, &exact_caps, GasSchedule::EthereumPectraSingleOpV07V1),
        Err(GasPolicyError::CapExceeded {
            field: "preVerificationGas"
        })
    );
}

#[test]
fn entrypoint_uint120_boundary_is_checked_for_every_gas_and_fee_field() {
    let max = ENTRY_POINT_V07_FIELD_MAX;
    validate_entrypoint_v07_width(max, max, max, max, max).unwrap();
    let over = max + U256::from(1);
    let cases = [
        (
            validate_entrypoint_v07_width(over, max, max, max, max),
            "callGasLimit",
        ),
        (
            validate_entrypoint_v07_width(max, over, max, max, max),
            "verificationGasLimit",
        ),
        (
            validate_entrypoint_v07_width(max, max, over, max, max),
            "preVerificationGas",
        ),
        (
            validate_entrypoint_v07_width(max, max, max, over, max),
            "maxFeePerGas",
        ),
        (
            validate_entrypoint_v07_width(max, max, max, max, over),
            "maxPriorityFeePerGas",
        ),
    ];
    for (actual, field) in cases {
        assert_eq!(actual, Err(GasPolicyError::EntryPointFieldWidth { field }));
    }
}

#[test]
fn priority_fee_must_not_exceed_max_fee() {
    let mut input = input();
    input.max_priority_fee_per_gas = input.max_fee_per_gas + U256::from(1);
    assert_eq!(
        authorize_no_paymaster(
            &input,
            &permissive_caps(),
            GasSchedule::EthereumPectraSingleOpV07V1
        ),
        Err(GasPolicyError::PriorityFeeAboveMaxFee)
    );
}

#[test]
fn nonempty_paymaster_data_is_rejected() {
    let mut input = input();
    input.paymaster_and_data = Bytes::from(vec![0x01]);
    assert_eq!(
        authorize_no_paymaster(
            &input,
            &permissive_caps(),
            GasSchedule::EthereumPectraSingleOpV07V1
        ),
        Err(GasPolicyError::PaymasterNotSupported)
    );
}

#[test]
fn maximum_liability_accepts_exact_and_rejects_one_wei_over_cap() {
    let input = input();
    let pvg = conservative_pre_verification_gas(&input, GasSchedule::EthereumPectraSingleOpV07V1)
        .unwrap();
    let liability = checked_max_liability_no_paymaster(
        input.call_gas_limit,
        input.verification_gas_limit,
        pvg,
        input.max_fee_per_gas,
    )
    .unwrap();
    let mut caps = permissive_caps();
    caps.max_liability = liability;
    assert_eq!(
        authorize_no_paymaster(&input, &caps, GasSchedule::EthereumPectraSingleOpV07V1)
            .unwrap()
            .max_liability,
        liability
    );
    caps.max_liability = liability - U256::from(1);
    assert_eq!(
        authorize_no_paymaster(&input, &caps, GasSchedule::EthereumPectraSingleOpV07V1),
        Err(GasPolicyError::CapExceeded {
            field: "maxLiability"
        })
    );
}

#[test]
fn liability_arithmetic_rejects_addition_and_multiplication_overflow() {
    assert_eq!(
        checked_max_liability_no_paymaster(U256::MAX, U256::from(1), U256::ZERO, U256::from(1)),
        Err(GasPolicyError::ArithmeticOverflow {
            operation: "gas limit sum"
        })
    );
    assert_eq!(
        checked_max_liability_no_paymaster(
            U256::MAX / U256::from(2) + U256::from(1),
            U256::ZERO,
            U256::ZERO,
            U256::from(2)
        ),
        Err(GasPolicyError::ArithmeticOverflow {
            operation: "maximum liability"
        })
    );
}

#[test]
fn zero_and_nonzero_calldata_match_the_exact_conservative_formula() {
    let mut zero = input();
    zero.call_data = Bytes::from(vec![0x00; 64]);
    let zero_reference = reference_cost(&zero);
    assert_eq!(
        conservative_pre_verification_gas(&zero, GasSchedule::EthereumPectraSingleOpV07V1).unwrap(),
        zero_reference.with_margin
    );

    let mut nonzero = zero.clone();
    nonzero.call_data = Bytes::from(vec![0xff; 64]);
    let nonzero_reference = reference_cost(&nonzero);
    assert_eq!(
        conservative_pre_verification_gas(&nonzero, GasSchedule::EthereumPectraSingleOpV07V1)
            .unwrap(),
        nonzero_reference.with_margin
    );
    assert!(nonzero_reference.with_margin > zero_reference.with_margin);
}

#[test]
fn signature_length_is_strictly_monotonic() {
    let mut input = input();
    let mut previous = None;
    for signature_len in [0, 1, 2, 31, 32, 33, 64, 65, 480, 481] {
        input.signature_len = signature_len;
        let current =
            conservative_pre_verification_gas(&input, GasSchedule::EthereumPectraSingleOpV07V1)
                .unwrap();
        if let Some(previous) = previous {
            assert!(current > previous, "signature length {signature_len}");
        }
        previous = Some(current);
    }
}

#[test]
fn pectra_floor_binds_for_calldata_heavy_operation() {
    let mut input = input();
    input.call_data = Bytes::from(vec![0xff; 8_192]);
    let reference = reference_cost(&input);
    assert!(reference.pectra_floor > reference.legacy);
    assert_eq!(reference.selected, reference.pectra_floor);
    assert_eq!(
        conservative_pre_verification_gas(&input, GasSchedule::EthereumPectraSingleOpV07V1)
            .unwrap(),
        reference.with_margin
    );
}

#[test]
fn safety_margin_rounds_up_instead_of_truncating() {
    let mut candidate = input();
    let (candidate, reference) = (0..256)
        .find_map(|signature_len| {
            candidate.signature_len = signature_len;
            let reference = reference_cost(&candidate);
            let numerator = reference.selected * U256::from(SAFETY_NUMERATOR);
            (numerator % U256::from(SAFETY_DENOMINATOR) != U256::ZERO)
                .then(|| (candidate.clone(), reference))
        })
        .expect("a fixture whose safety multiplication has a remainder");
    let numerator = reference.selected * U256::from(SAFETY_NUMERATOR);
    assert_eq!(
        reference.with_margin,
        numerator / U256::from(SAFETY_DENOMINATOR) + U256::from(1)
    );
    assert_eq!(
        conservative_pre_verification_gas(&candidate, GasSchedule::EthereumPectraSingleOpV07V1)
            .unwrap(),
        reference.with_margin
    );
}

#[test]
fn estimator_uses_nonzero_beneficiary_and_all_nonzero_signature_shape() {
    let input = input();
    let packed = packed_for_cost(&input);
    let signature = vec![0xff; input.signature_len];
    let zero_beneficiary = encode_single_handle_ops(&packed, &signature, Address::ZERO);
    let nonzero_beneficiary =
        encode_single_handle_ops(&packed, &signature, Address::from([0xff; 20]));
    let calldata_cost = |data: &Bytes| {
        data.iter()
            .map(|byte| if *byte == 0 { 4_u64 } else { 16_u64 })
            .sum::<u64>()
    };
    assert!(calldata_cost(&nonzero_beneficiary) > calldata_cost(&zero_beneficiary));
    assert_eq!(
        conservative_pre_verification_gas(&input, GasSchedule::EthereumPectraSingleOpV07V1)
            .unwrap(),
        reference_cost(&input).with_margin
    );
}

#[test]
fn authorization_recomputes_liability_without_a_daemon_prefund_input() {
    let input = input();
    let AuthorizedGasPlan {
        pre_verification_gas,
        max_liability,
        ..
    } = authorize_no_paymaster(
        &input,
        &v1_owner_caps(),
        GasSchedule::EthereumPectraSingleOpV07V1,
    )
    .unwrap();
    let independently_recomputed = checked_max_liability_no_paymaster(
        input.call_gas_limit,
        input.verification_gas_limit,
        pre_verification_gas,
        input.max_fee_per_gas,
    )
    .unwrap();
    assert_eq!(max_liability, independently_recomputed);
    assert_ne!(max_liability, U256::ZERO);
    assert_ne!(max_liability, U256::MAX);
}

#[test]
fn handle_ops_encoder_uses_entrypoint_v07_selector() {
    let input = input();
    let calldata =
        encode_single_handle_ops(&packed_for_cost(&input), &[0xab], Address::from([0x22; 20]));
    assert_eq!(&calldata[..4], &[0x76, 0x5e, 0x82, 0x7f]);
}
