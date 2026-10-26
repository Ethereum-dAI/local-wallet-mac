"""Shared by the aave-v3-lend scripts: token lookup, unit conversion, on-chain reads."""

from decimal import ROUND_DOWN, Decimal, InvalidOperation

import edw_skill

RESERVE_DATA = (
    "function getReserveData(address asset) view returns ((uint256,uint128,uint128,uint128,uint128,"
    "uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128))"
)
ACCOUNT = (
    "function getUserAccountData(address user) view returns (uint256 collateral,uint256 debt,"
    "uint256 canBorrow,uint256 liquidationThreshold,uint256 ltv,uint256 healthFactor)"
)
USER_CONFIGURATION = "function getUserConfiguration(address user) view returns (uint256)"
ADDRESSES_PROVIDER = "function ADDRESSES_PROVIDER() view returns (address)"
PRICE_ORACLE = "function getPriceOracle() view returns (address)"
ASSET_PRICE = "function getAssetPrice(address asset) view returns (uint256)"
BALANCE_OF = "function balanceOf(address owner) view returns (uint256)"
ALLOWANCE = "function allowance(address owner,address spender) view returns (uint256)"
BORROW_ALLOWANCE = "function borrowAllowance(address fromUser,address toUser) view returns (uint256)"
MAX = 2**256 - 1
UINT_MAX = str(MAX)
VARIABLE = "2"
RAY = Decimal(10) ** 27
SECONDS_PER_YEAR = 31_536_000
# Aave's base currency: USD with 8 decimals.
BASE = Decimal(10) ** 8
# Aave v3.2 dropped the interest-rate-mode argument from the WETH gateway's borrowETH and
# repayETH; the gateway on these chains is older and still takes it.
GATEWAY_TAKES_RATE_MODE = {11155111}


def started():
    """(args, context, pool) once the wallet is unlocked on a chain this skill knows."""
    _, args, context = edw_skill.invoke()
    if not context.get("me"):
        edw_skill.fail("the wallet is locked; unlock a network first (Aave needs its chain and address)")
    pool = context.get("contracts", {}).get("pool")
    if not pool:
        edw_skill.fail(f"this skill does not know Aave v3 on chain {context.get('chain_id')}")
    return args, context, pool


def reserves(context):
    """(id, token info) of each asset Aave lends here: a token listed beside its a-token."""
    tokens = context.get("tokens", {})
    return [(token_id, info) for token_id, info in tokens.items() if "a" + token_id in tokens]


def asset(context, symbol):
    """(id, token info, native) for USDC, USDT, DAI, WETH, or ETH: Aave's WETH, sent as ether."""
    native = str(symbol).upper() == "ETH"
    wanted = "WETH" if native else str(symbol).upper()
    for token_id, info in reserves(context):
        if info["symbol"].upper() == wanted:
            return token_id, info, native
    known = sorted(i["symbol"] for _, i in reserves(context)) + ["ETH"]
    edw_skill.fail(f"{symbol} is not one this skill lends on this chain ({', '.join(known)})")


def shown(info, native):
    return "ETH" if native else info["symbol"]


def a_token(context, token_id):
    return context["tokens"].get("a" + token_id)


def debt_token(context, token_id):
    return context["tokens"].get(token_id + "_debt")


def gateway(context):
    address = context.get("contracts", {}).get("gateway")
    if not address:
        edw_skill.fail(
            f"this skill does not know Aave's WETH gateway on chain {context['chain_id']}; use WETH instead of ETH"
        )
    return address


def gateway_rate_mode(context):
    """The interest-rate-mode argument this chain's gateway takes in borrowETH and repayETH."""
    return [VARIABLE] if context["chain_id"] in GATEWAY_TAKES_RATE_MODE else []


def base_units(amount, decimals, symbol):
    try:
        value = Decimal(str(amount))
    except InvalidOperation:
        edw_skill.fail(f"`{amount}` is not an amount of {symbol}")
    if value <= 0:
        edw_skill.fail(f"the amount of {symbol} must be positive")
    units = value * (Decimal(10) ** decimals)
    if units != units.to_integral_value():
        edw_skill.fail(f"{symbol} has {decimals} decimals; `{amount}` has more")
    return int(units)


def whole(units, decimals):
    text = format(Decimal(units) / (Decimal(10) ** decimals), "f")
    return text.rstrip("0").rstrip(".") if "." in text else text


def with_interest_margin(units):
    """A debt plus 0.01%: interest accrues every second until a repayment is mined."""
    return units + units // 10_000 + 1


def balance(token_address, owner):
    return int(edw_skill.call(token_address, BALANCE_OF, [owner])[0])


def held(info, native, owner):
    return edw_skill.get_balance(owner) if native else balance(info["address"], owner)


def approve_steps(token_id, token_address, spender_id, spender_address, owner, amount):
    """The approve steps that let the spender take exactly `amount`, none if it already may."""
    allowance = int(edw_skill.call(token_address, ALLOWANCE, [owner, spender_address])[0])
    if allowance >= amount:
        return []
    steps = []
    if allowance > 0:
        # USDT refuses to change a non-zero allowance to another non-zero one.
        steps.append(edw_skill.approve_step(token_id, spender_id, 0))
    steps.append(edw_skill.approve_step(token_id, spender_id, amount))
    return steps


def reserve(pool, asset_address):
    return edw_skill.call(pool, RESERVE_DATA, [asset_address])[0]


def borrowable(pool, asset_address):
    """Whether Aave lends the asset now: its reserve is active (bit 56), not frozen (57) or
    paused (60), and has borrowing on (58)."""
    configuration = int(reserve(pool, asset_address)[0])

    def bit(n):
        return (configuration >> n) & 1

    return bit(56) and not bit(57) and bit(58) and not bit(60)


def apy(rate):
    """Percent per year, compounded per second from a per-year rate in ray."""
    per_second = Decimal(rate) / RAY / SECONDS_PER_YEAR
    return float(round(((1 + per_second) ** SECONDS_PER_YEAR - 1) * 100, 3))


def account(pool, owner):
    """getUserAccountData as ints: collateral, debt, canBorrow (USD, 8 decimals),
    liquidationThreshold, ltv (basis points), healthFactor (18 decimals)."""
    return [int(v) for v in edw_skill.call(pool, ACCOUNT, [owner])]


def cut(value):
    """Two decimals, cut so a health factor never reads higher than it is (0.999 is not 1.00)."""
    return str(Decimal(value).quantize(Decimal("0.01"), rounding=ROUND_DOWN))


def health(value):
    return "none (no debt)" if value == MAX else cut(Decimal(value) / 10**18)


def usd(base):
    return f"{Decimal(base) / BASE:.2f}"


def price(pool, asset_address):
    """The asset's price in Aave's base currency (USD, 8 decimals), from Aave's own oracle."""
    provider = edw_skill.call(pool, ADDRESSES_PROVIDER)[0]
    oracle = edw_skill.call(provider, PRICE_ORACLE)[0]
    return int(edw_skill.call(oracle, ASSET_PRICE, [asset_address])[0])


def is_collateral(pool, owner, asset_address):
    """Bit 2*id+1 of the user's configuration: the reserve is used as collateral."""
    reserve_id = int(reserve(pool, asset_address)[7])
    configuration = int(edw_skill.call(pool, USER_CONFIGURATION, [owner])[0])
    return bool((configuration >> (2 * reserve_id + 1)) & 1)
