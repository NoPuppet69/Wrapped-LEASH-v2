# LEASH V2: WrappedLeash

An **ownerless, non-rebasing, two-way ERC-20 wrapper** for legacy LEASH v1.

Deposit v1 to get a balance that never changes on its own. Burn it to get your share of v1 back whenever you like. Nobody is forced to migrate, nothing is burned, and nobody holds admin keys.

> Looking for the fixed-supply token with a one-way burn migration? See [`README-LeashV2-Migrator.md`](./README-LeashV2-Migrator.md).

---

## At a glance

| | |
|---|---|
| Name / symbol | `LEASH V2` / `LEASH` (18 decimals) |
| Underlying | LEASH v1, `0x27C70Cd1946795B66be9d954418546998b546634` (Ethereum) |
| Max supply | **107,646.4693** (`MAX_WRAPPED`), reached only if *all* v1 is wrapped |
| Owner / admin | **None** |
| Pause, tax, blacklist, fee | **None** |
| Mint path | Only by depositing v1 |
| Upgradeable | No |
| Solidity | `^0.8.20`, self-contained, no imports |

---

## How it works

Each LEASH V2 token is a **fixed share of the current v1 supply**, not a 1:1 copy of a v1 unit. It's the same design as Ampleforth's WAMPL.

Every call reads v1's live `totalSupply()` (it's never stored):

```
wrapped    = v1Amount      × MAX_WRAPPED      ÷ v1.totalSupply()
underlying = wrappedAmount × v1.totalSupply() ÷ MAX_WRAPPED
```

**Why rebases don't touch your share:** a rebase scales every v1 balance by the same factor, including the v1 locked in this contract. Your LEASH V2 balance stays the same, and `W` LEASH V2 always redeems for `W / 107,646.4693` of the v1 supply *at that moment*. The pie can grow or shrink, but your slice doesn't.

**Example** at today's v1 supply (803,760,032,105,055,242.2456…):

- Depositing 100 v1 mints `13392861` wei, or `0.000000000013392861` LEASH V2.
- If v1 then rebases 2×, that same balance unwraps for about 200 v1.

### Rounding always favours the contract

| Action | Rounds |
|---|---|
| `deposit` / `depositFor` | mints **down**, based on the v1 *actually received* (balance delta) |
| `mint` / `mintFor` | pulls **up** the v1 required |
| `withdraw` / `withdrawTo` | burns **up** the LEASH V2 required |
| `burn` / `burnTo` / `burnAll` / `withdrawAll` | pays **down** the v1 |

Zero amounts, including conversions that round down to zero, revert. Round trips can't make a profit, and the dust that's left over stays behind as extra backing.

---

## Functions

### Wrap

| Function | You specify | Effect |
|---|---|---|
| `deposit(uAmount)` | v1 in | mints LEASH V2 to you |
| `depositFor(to, uAmount)` | v1 in | mints LEASH V2 to `to` |
| `mint(wAmount)` | LEASH V2 out | pulls the v1 needed from you |
| `mintFor(to, wAmount)` | LEASH V2 out | pulls from you, mints to `to` |

Approve the wrapper on v1 first: `v1.approve(wrapper, amount)`.

### Unwrap

| Function | You specify | Effect |
|---|---|---|
| `withdraw(uAmount)` / `withdrawTo(to, uAmount)` | v1 out | burns the LEASH V2 needed |
| `withdrawAll()` / `withdrawAllTo(to)` | none | burns your whole balance |
| `burn(wAmount)` / `burnTo(to, wAmount)` | LEASH V2 in | sends you the v1 |
| `burnAll()` / `burnAllTo(to)` | none | burns your whole balance |

### Views

| Function | Returns |
|---|---|
| `underlying()` | v1 token address |
| `totalUnderlying()` | v1 redeemable by all holders, `wrapperToUnderlying(totalSupply())` |
| `balanceOfUnderlying(account)` | v1 that `account` could withdraw right now |
| `underlyingToWrapper(uAmount)` | LEASH V2 for a v1 amount, at the live supply |
| `wrapperToUnderlying(wAmount)` | v1 for a LEASH V2 amount, at the live supply |

### ERC-20

`totalSupply`, `balanceOf`, `transfer`, `transferFrom`, `approve`, `allowance`, `increaseAllowance`, and `decreaseAllowance`. There's no `permit`. Transfers to `address(0)` or to the wrapper itself revert.

### Events

`Transfer`, `Approval`, `Deposit(from, to, underlyingAmount, wrappedAmount)`, `Withdraw(from, to, underlyingAmount, wrappedAmount)`.

---

## Safety properties

- **Always fully backed.** The v1 it holds is always ≥ what all LEASH V2 holders can redeem (`totalUnderlying()`). This is checked by invariant tests under random deposits, withdrawals, transfers, and rebases up and down.
- **No admin paths.** No owner, no pause, no blacklist, no fee, no rescue function. v1 donated directly to the contract just becomes extra backing.
- **Reentrancy guarded** on every function that wraps or unwraps.
- **512-bit `mulDiv`**, so there's no overflow at any realistic v1 supply.

### Verified on-chain about v1 (22 Nov 2026)

- v1 `owner()` is `0x0` (renounced), so nobody can pause v1 or freeze the locked tokens.
- The EIP-1967 implementation, admin, and beacon slots are empty, and the address holds the full UFragments runtime. **It isn't a proxy and can't be upgraded.**

### Remaining caveat

v1 can still rebase through its monetary policy (`0xEff020b07a292baad7A948897c87F99e4Fe6636B`, owner renounced). Its market oracle (`0x8a920C8565783c3aE4aA236e92A5227c4A3eeDcB`) still has an owner (`0x01e0C58EebE0e8B8435458B191a9bb049DC5c50b`) and a single provider (`0x44539732152752EA9568E69440BFB910B0d474b5`). Those keys can change how many v1 *units* exist, but they **can't** mint LEASH V2, seize locked v1, or change any holder's share.

---

## Deploy

```solidity
new WrappedLeash(0x27C70Cd1946795B66be9d954418546998b546634);
```

That's the only constructor argument. It reverts if the address is zero or if v1's supply is zero. Once it's deployed there's nothing to configure and nothing to renounce.

---

## Tests

Foundry, run against a mock rebasing token **and** the actual compiled v1 UFragments bytecode.

| Suite | Tests |
|---|---|
| `test/WrappedLeash.t.sol` | 20 (conversions, every wrap and unwrap path, rounding direction, rebases up and down, dust, reentrancy, recipients) |
| `test/WrappedLeash.invariant.t.sol` | 4 invariants (always backed, supply ≤ `MAX_WRAPPED`, `totalUnderlying` matches its definition, balances sum to `totalSupply`) |

```bash
forge build
forge test -vv
```

## License

MIT
