"""Shared by the aave-v3-lend scripts: token lookup, unit conversion, on-chain reads."""

from decimal import Decimal, InvalidOperation

import edw_skill

RESERVE_DATA = (
    "function getReserveData(address asset) view returns ((uint256,uint128,uint128,uint128,uint128,"
    "uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128))"
)
BALANCE_OF = "function balanceOf(address owner) view returns (uint256)"
ALLOWANCE = "function allowance(address owner,address spender) view returns (uint256)"
UINT_MAX = str(2**256 - 1)
RAY = Decimal(10) ** 27
SECONDS_PER_YEAR = 31_536_000


def token(context, symbol):
    """(id, token info) for a movable token given by symbol, e.g. "usdc", {...}."""
    for token_id, info in context.get("tokens", {}).items():
        if info.get("movable") and info["symbol"].upper() == str(symbol).upper():
            return token_id, info
    known = sorted(i["symbol"] for i in context.get("tokens", {}).values() if i.get("movable"))
    edw_skill.fail(f"{symbol} is not one this skill lends on this chain ({', '.join(known)})")


def a_token(context, token_id):
    return context["tokens"].get("a" + token_id)


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


def balance(token_address, owner):
    return int(edw_skill.call(token_address, BALANCE_OF, [owner])[0])


def supply_apy(pool, asset):
    """Percent per year, compounded per second from the current liquidity rate (a ray)."""
    reserve = edw_skill.call(pool, RESERVE_DATA, [asset])[0]
    rate = Decimal(reserve[2]) / RAY
    apy = (1 + rate / SECONDS_PER_YEAR) ** SECONDS_PER_YEAR - 1
    return float(round(apy * 100, 3)), reserve[8]
