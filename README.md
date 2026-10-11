# RNNN on Robinhood Chain: token and IMD fee hook

The rnnn.io community token **RNNN** and the Uniswap v4 hook for its RNNN/IMD pool. The hook has
exactly one rule: on every swap it takes 1% of the swap's IMD side, in IMD, and sends it to
`0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4`. It never swaps or sells the fee, has no owner, no pause,
no mint, no other fee, and does not block or alter swaps in any other way.

## Contracts

| Contract                          | File                     | Purpose                                                                 |
| --------------------------------- | ------------------------ | ----------------------------------------------------------------------- |
| `RNNNToken`                       | `src/RNNNToken.sol`      | Plain fixed-supply ERC-20: name `RNNN`, symbol `RNNN`, 18 decimals      |
| `RNNNImdFeeHook`                  | `src/RNNNImdFeeHook.sol` | The one-rule fee hook                                                   |
| `HookFlags` (library, internal)   | `src/HookFlags.sol`      | Permission bits and address matching used by tests and the deploy script |
| `DeployRNNN` (script)             | `script/Deploy.s.sol`    | Rehearsal deployment; the IMD factory does the real one                 |

### RNNNToken

Exactly 1,000,000,000 RNNN (10^27 minor units) are minted once, to `msg.sender`, in the constructor.
`msg.sender` is the IMD launch factory, which then distributes the supply under the launch policy
(80% to the pool, 10% to the swarm's MerkleDistributor, 10% to the payer). The token has no owner,
mint, burn, pause, blocklist, transfer fee or upgrade path. The swap fee the brief asks for lives in
the hook, as the launch rules require.

### RNNNImdFeeHook

Constructor arguments, all immutable:

| Argument        | Manifest value                                       | Meaning                                  |
| --------------- | ---------------------------------------------------- | ---------------------------------------- |
| `poolManager_`  | `$poolManager`                                       | The chain's Uniswap v4 PoolManager       |
| `imd_`          | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`         | IMD on Robinhood Chain, the pair currency |
| `feeRecipient_` | `0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4`         | Where every fee goes; can never change   |

The constructor rejects a zero address for any of the three and checks that the address the hook is
deployed at carries exactly its permission bits. It calls no other contract, so it runs on an empty
chain.

#### The fee rule

The fee is `FEE_BPS = 100` basis points (1%, floor) of the IMD the pool actually trades in the swap:
the pool's IMD leg, read from the pool's own `BalanceDelta` in `afterSwap`. The same base applies to
all four swap shapes. It is always taken on the IMD side and always paid in IMD. The RNNN side is
never touched.

| Swap                                | IMD is the…        | Charged in   | Effect on the swapper, full fill                                |
| ----------------------------------- | ------------------ | ------------ | --------------------------------------------------------------- |
| Buy, exact input (spend X IMD)      | specified currency | `beforeSwap` | Pays exactly X; the pool trades E = X − X/101; fee = X/101 = E/100 |
| Buy, exact output (want R RNNN)     | unspecified        | `afterSwap`  | Gets exactly R; pays the pool's IMD leg E plus E/100            |
| Sell, exact input (spend R RNNN)    | unspecified        | `afterSwap`  | Spends exactly R; receives the pool's IMD leg E minus E/100     |
| Sell, exact output (want Y IMD)     | specified currency | `beforeSwap` | Receives exactly Y; the pool pays out E = Y + Y/99; fee = Y/99 = E/100 |

When IMD is the unspecified currency, `afterSwap` knows the pool's IMD leg and charges 1% of it
through `afterSwapReturnDelta`. When IMD is the specified currency, v4 only lets a hook charge that
currency in `beforeSwap`, before the fill is known, so `beforeSwap` declares the fee a full fill owes
(X/101 or Y/99, chosen so that it equals 1% of the pool's leg when everything trades) through
`beforeSwapReturnDelta`, and `afterSwap` trues it up against the executed amount:

- **Full fill** (the normal case): the declared fee is exactly the fee owed. Nothing else happens.
- **Short fill**: the pool stopped at the swap's `sqrtPriceLimitX96` or ran out of liquidity, so it
  traded E less than the order. The fee owed is E/100 and the hook returns the rest of the declared
  fee to the swapper's router inside the same unlock (`take` to the hook, `sync`, transfer back,
  `settleFor(router)`), so the router settles E plus E/100 and the swapper pays nothing on the part
  that did not trade. `FeeRefunded(amount)` is emitted. The refund is paid from the IMD the
  PoolManager holds; if it holds less than the refund (the launch pool before its first buy has
  settled, or an order larger than all the IMD in existence) the swap is refused with
  `ShortFillNotRefundable` instead of being mischarged. A refused swap moves no funds and books
  nothing for the recipient. An exact-output sell that can fill nothing (no IMD liquidity) is refused
  the same way rather than charging the seller for IMD they never received.

Routers that settle the PoolManager's recorded delta after the swap (the Universal Router's
`SETTLE_ALL`/`TAKE_ALL`, `V4Router`) receive the refund automatically. A router that instead settles
the exact `BalanceDelta` the swap returned, as v4-core's `PoolSwapTest` does, overpays by the refund
on a short fill and reverts with `CurrencyNotSettled`; such routers fill fully or not at all. Tests
use both: `PoolSwapTest` for full fills and `test/mocks/ActualDeltaRouter.sol` for short fills.

The declared delta is never larger than the swap amount (at most 1/99 of it), so the hook cannot
"no-op" a swap or keep the swapper's input, and it is clamped to the `int128` range so an oversized
order fails in the pool's own terms rather than on a cast. Swaps whose IMD leg is below 100 wei pay
no fee and go through unchanged.

#### How the fee reaches the recipient

The hook settles the fee inside the same swap, in `afterSwap`:

- If the PoolManager already holds at least the fee in IMD and the recipient accepts the transfer,
  the hook calls `take` and the recipient receives the IMD immediately. An earlier deferred claim
  (below) is delivered along with it as far as the balance allows.
- If the manager does not hold enough, or the `take` reverts because IMD refuses the transfer to the
  recipient (IMD on Robinhood Chain has an owner-controlled blocklist), the hook mints itself an
  ERC-6909 claim for the fee on the PoolManager instead. The first case happens on the very first
  buys of a launch pool: the pool is seeded with RNNN only, so the manager holds no IMD until the
  first buyer's input settles, which happens after `afterSwap`. In both cases the swap itself
  succeeds at the full amount; nothing reverts.

Deferred claims are redeemed either by the next swap that finds enough IMD in the manager, or by
anyone calling `collectPending()`, which unlocks the manager, burns the claim and takes the IMD to
the fixed recipient. `pendingFees()` reports the outstanding claim. Both functions are permissionless
and the recipient cannot be changed by anyone.

The recipient receives IMD by an ERC-20 transfer from the PoolManager, so a contract recipient does
not need a `receive` function and there is no ETH anywhere in this design. The brief's instruction
that the recipient receives IMD, not ETH or another token, overrides the generic launch guidance about
settling hook fees in ETH; nothing is sold, and no price limit or ETH market is involved.

#### Pool initialization

`beforeInitialize` is enabled so nobody can open the launch pool before the hook has code. It accepts
any initializer (the IMD factory, or anyone else), any LP fee tier including the manifest's 12500, and
any tick spacing. Its only check is that one side of the pool is IMD, since a pool with no IMD side
has no IMD to take the fee from. All other callbacks revert with `HookNotImplemented` and are not
advertised in the hook address.

#### Hook configuration record

```json
{
  "hook": "BaseHook",
  "name": "RNNNImdFeeHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": true,
  "transientStorage": false,
  "shares": {"options": false},
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": true,
    "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none",
  "info": {"license": "MIT"}
}
```

`access` is none by design: the brief forbids an owner. v4-periphery no longer ships `BaseHook`, so the
hook implements `IHooks` directly with the same `onlyPoolManager` guard on every callback and the same
address validation in the constructor. Permission bits: `0x20CC`
(`BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURN_DELTA | AFTER_SWAP_RETURN_DELTA`).

## Launch parameters

Decided by the launch, recorded here for the manifest step (this repository deliberately contains no
`launch.json`):

| Parameter             | Value                                                  |
| --------------------- | ------------------------------------------------------ |
| Chain                 | Robinhood Chain, chain id 4663                         |
| Pair currency         | IMD, `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`, 18 decimals |
| LP fee                | 12500 (1.25%), the launch policy's tier                |
| Tick spacing          | 60                                                     |
| Initial price         | derived by the deployer from the 2,500 IMD opening market cap |
| Token supply          | 1,000,000,000 RNNN, minted to the factory              |
| Hook fee              | 1% of the IMD the pool trades in every swap, paid in IMD |
| Hook fee recipient    | `0x45C89d0CF0B8a05218506236FcfcB18DA1D3ebE4`           |
| Owner                 | none: the hook and token have no owner or admin        |

The hook's LP fee is the pool's; the hook's 1% comes on top of it. The hook does not require or
reject any particular LP fee.

## Assumptions

- IMD is an ERC-20 with no transfer fee or rebasing. If IMD refuses a transfer to the fee recipient
  (its blocklist), fees are held as claims and swaps continue; `collectPending` reverts until IMD
  accepts the transfer again, then delivers everything. If IMD refused transfers to or from the hook
  itself, short fills could not be refunded and would be refused, while full fills would still trade
  (their fee goes straight from the manager to the recipient). If IMD disabled transfers altogether,
  no swap on any IMD pool could settle, hook or not.
- Routers settle their input after the swap, as the Universal Router and v4-core's test routers do.
  A router that `sync`s IMD before calling `swap` and settles afterwards would see its settlement
  reduced by any fee the hook `take`s in between; that is the standard v4 caveat on `sync`. Routers
  that settle the recorded delta receive short-fill refunds; routers that settle the returned
  `BalanceDelta` exactly cannot complete a short fill (see the fee rule above).
- The fee is 1% floor of the IMD the pool actually trades, on every swap shape, as the table above
  defines it. On a full-fill exact-input buy the declared X/101 can be one wei under floor(E/100)
  when X mod 101 = 100; the hook never charges more than it declared. Swaps below 100 wei of IMD pay
  nothing.
- Short fills are refunded from the PoolManager's IMD balance. Before the launch pool's first buy
  settles the manager holds no IMD, so a price-limited or liquidity-exhausted IMD-specified swap in
  that window is refused with `ShortFillNotRefundable`; a full fill, which needs no refund, trades
  normally. Routers that set no price limit (the Universal Router's default) only fill short when
  liquidity runs out.
- Only the pool's IMD side is charged. If this hook were attached to a different IMD pool (it accepts
  any pool with an IMD side), it would apply the same rule there, paying the same recipient.

## Operational responsibilities

There is nothing to administer. The only operational action is optional:

- **Deferred fees.** After launch, until buyers have put enough IMD into the pool, early fees are
  held as ERC-6909 claims (`pendingFees()`). The same happens to any fee whose transfer to the
  recipient IMD refuses. They are delivered automatically by later swaps. Anyone, including the
  recipient, may call `collectPending()` at any time to deliver whatever the manager's IMD balance
  covers and IMD accepts. Watch the `FeeDeferred`, `FeePaid` and `FeeRefunded` events.
- **No upgrades, no pauses, no parameter changes** are possible. A different fee or recipient needs a
  new hook and a new pool.

## Building and testing

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`, and
disables `ffi`. Dependencies are vendored as ordinary files under `lib/` (forge-std, Uniswap
v4-core's `src/` and `test/utils/CurrencySettler.sol`, solmate's `Owned.sol`), so the build needs no
network and no submodules.

Test coverage (`test/`):

- `RNNNImdFeeHook.t.sol`: exact-input and exact-output buys and sells each pay exactly 1% of the IMD
  side the pool traded to the fixed recipient, and the base is the same on all four shapes; fuzzed
  conservation of IMD and floor(1%) fee; tiny swaps pay nothing; hook data is ignored; liquidity
  operations pay no fee; callbacks refuse any caller but the PoolManager; undeclared callbacks are
  unreachable; there are no privileged functions (a selector sweep from several callers, plus no ETH
  entry point); the runtime code has no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`; permissions
  match the mined address; the constructor rejects zero addresses and an unflagged address.
- `RNNNImdFeeHookInitializeTest`: the factory opens the launch pool at fee 12500 and spacing 60;
  anyone may open an IMD pool at another tier; a pool with no IMD side is refused; `beforeInitialize`
  refuses non-manager callers.
- `RNNNImdFeeHookFreshPoolTest`: a fresh PoolManager whose pool holds RNNN only. The first buy
  succeeds and defers the fee as a claim; anyone can collect it; the next swap delivers it along with
  its own fee; the recipient never receives RNNN; an exact-output sell that can fill nothing is
  refused and charges the seller nothing; a price-limited buy before any IMD is in the manager is
  refused, and after the first buy is trued up to its fill.
- `RNNNImdFeeHookShortFillTest`: on a funded pool, a price-limited exact-input buy and exact-output
  sell each pay 1% of the IMD that traded and nothing on the unfilled rest, the refund is emitted,
  a full fill through the actual-delta router needs no refund, an order beyond `int128` fails with
  `ShortFillNotRefundable` rather than an overflow, and a large order the manager can refund is trued
  up.
- `RNNNImdFeeHookBlockedRecipientTest`: with the recipient blocked by IMD, buys and sells still trade
  and defer the fee as a claim; `collectPending` reverts while blocked and delivers everything once
  unblocked; the next swap after unblocking delivers everything.
- `RNNNToken.t.sol`: supply, decimals, transfer and allowance behaviour, no admin selectors, no
  escape-hatch opcodes.
- `Deploy.t.sol`: the deploy function mines a flagged address and wires the constructor arguments.

Tests read no environment variables and depend on no caller address, so they run in any order and in
parallel.

## Deployment

The IMD launch factory deploys `RNNNToken` and `RNNNImdFeeHook` from their built bytecode, mines the
hook's CREATE2 salt for the `0x20CC` permission bits, and initializes the pool in the same transaction.
Nothing in this repository needs to run for that.

`script/Deploy.s.sol` is a rehearsal for a local or test chain. `run()` reads `POOL_MANAGER` (and
optionally `IMD`, defaulting to IMD on Robinhood Chain) from the environment, then calls `deploy`,
which tests also call directly with their own values. Under `forge script --broadcast` the salted
`new` goes through Forge's deterministic CREATE2 deployer, which `deploy` mines against.

## Security notes

This work has tests, not an audit. Points a reviewer should check:

- `beforeSwapReturnDelta` is enabled. The delta returned is `|amountSpecified| / 101` (exact input)
  or `/ 99` (exact output) in the specified currency, clamped to `int128`, and only when that
  currency is IMD; it can never exceed the swap amount. `afterSwap` reads the pool's executed IMD
  amount from `delta` and never charges more than 1% of it: any excess the `beforeSwap` declaration
  took is returned to the router or the swap is refused.
- Every callback checks `msg.sender == poolManager`. The hook never reads `tx.origin` and never uses
  the `sender` argument for authorization; `sender` is used only as the address whose debt a
  short-fill refund is settled against, which is the router that called `PoolManager.swap`.
- The hook's deltas net to zero in every path: the fee credit from the returned delta is exactly
  offset by `take` or `mint` for the same amount in `afterSwap`, and a refund's `take` to the hook is
  offset by the transfer it settles for the router.
- The `take` to the recipient is wrapped in `try`/`catch`; the fallback mints a claim for the same
  amount, so the hook's delta still nets to zero and a reverting IMD transfer cannot halt swaps.
- The hook holds no tokens. Deferred fees exist only as ERC-6909 claims on the PoolManager and can
  only be delivered to the fixed recipient.
- No `DELEGATECALL`, `SELFDESTRUCT`, proxies, owners, or storage writes outside the PoolManager.
