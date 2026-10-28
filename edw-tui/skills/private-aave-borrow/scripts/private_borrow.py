"""private_aave_borrow: the Aave half of a private borrow, for an unshield's fresh account.

edw-tui runs it with what it derived from the user's request: `supply` (wei of the unshielded
ETH that goes to Aave as collateral), `token` and `borrow` (base units). The fresh account (`me`)
holds nothing yet, since the unshield brings the ETH in the same user operation, so no balance is
checked here. Aave's own state is: whether it takes ETH as collateral and lends the token now, and
whether the ETH can back the loan at Aave's prices.
"""

from decimal import ROUND_DOWN, Decimal

import edw_skill

RESERVE_DATA = (
    "function getReserveData(address asset) view returns ((uint256,uint128,uint128,uint128,uint128,"
    "uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128))"
)
ADDRESSES_PROVIDER = "function ADDRESSES_PROVIDER() view returns (address)"
PRICE_ORACLE = "function getPriceOracle() view returns (address)"
ASSET_PRICE = "function getAssetPrice(address asset) view returns (uint256)"
VARIABLE = "2"
# Aave's base currency: USD with 8 decimals.
BASE = Decimal(10) ** 8

_, args, context = edw_skill.invoke()
me = context.get("me")
contracts = context.get("contracts", {})
pool = contracts.get("pool")
if not me or not pool or not contracts.get("gateway"):
    edw_skill.fail(f"this skill knows Aave on Sepolia only, not chain {context.get('chain_id')}")

symbol = str(args.get("token", "")).upper()
token_id = next((i for i, t in context["tokens"].items() if t["symbol"].upper() == symbol), None)
if token_id is None or symbol == "WETH":
    edw_skill.fail(f"{symbol or 'that'} is not a token this skill borrows")
token = context["tokens"][token_id]
weth = context["tokens"]["weth"]
supply = int(args.get("supply", 0))
borrow = int(args.get("borrow", 0))
if supply <= 0 or borrow <= 0:
    edw_skill.fail("both the ETH supplied and the amount borrowed must be positive")


def whole(units, decimals=18):
    text = format(Decimal(units) / (Decimal(10) ** decimals), "f")
    return text.rstrip("0").rstrip(".") if "." in text else text


def configuration(asset):
    return int(edw_skill.call(pool, RESERVE_DATA, [asset])[0][0])


def bit(value, n):
    return (value >> n) & 1


def open_reserve(value):
    """Active (bit 56), not frozen (57) and not paused (60)."""
    return bit(value, 56) and not bit(value, 57) and not bit(value, 60)


collateral_config = configuration(weth["address"])
ltv = collateral_config & 0xFFFF
threshold = (collateral_config >> 16) & 0xFFFF
if not open_reserve(collateral_config) or ltv == 0:
    edw_skill.fail("Aave does not take ETH as collateral on this chain now")
loan_config = configuration(token["address"])
if not open_reserve(loan_config) or not bit(loan_config, 58):
    edw_skill.fail(f"Aave does not lend {symbol} on this chain now (borrowing it is turned off)")

oracle = edw_skill.call(edw_skill.call(pool, ADDRESSES_PROVIDER)[0], PRICE_ORACLE)[0]


def usd(units, asset, decimals):
    return units * int(edw_skill.call(oracle, ASSET_PRICE, [asset])[0]) // 10**decimals


collateral = usd(supply, weth["address"], 18)
debt = usd(borrow, token["address"], token["decimals"])
can_borrow = collateral * ltv // 10_000
if debt > can_borrow:
    edw_skill.fail(
        f"{whole(supply)} ETH lets the fresh account borrow about {Decimal(can_borrow) / BASE:.2f} USD "
        f"on Aave; {whole(borrow, token['decimals'])} {symbol} is about {Decimal(debt) / BASE:.2f} USD. "
        "Unshield more ETH or borrow less."
    )
health = (Decimal(collateral) * threshold / 10_000 / debt).quantize(Decimal("0.01"), rounding=ROUND_DOWN)
notes = [f"The fresh account's health factor after this borrow is about {health}, at Aave's prices now."]
if health < Decimal("1.5"):
    notes.append("That is below 1.5: a small fall in the ETH price could get the collateral liquidated.")

edw_skill.plan(
    [
        edw_skill.call_step("gateway", "depositETH", ["pool", "$self", "0"], value=supply),
        edw_skill.call_step("pool", "borrow", [token_id, str(borrow), VARIABLE, "0", "$self"]),
    ],
    notes,
)
