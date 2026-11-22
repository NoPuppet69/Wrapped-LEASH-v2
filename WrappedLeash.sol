// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUnderlying
 * @notice Minimal ERC-20 interface for the legacy LEASH v1 token.
 */
interface IUnderlying {
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/**
 * @title WrappedLeash (LEASH V2)
 * @notice An ownerless, non-rebasing ERC-20 wrapper for legacy LEASH v1
 *         (Ethereum `0x27C70Cd1946795B66be9d954418546998b546634`, the
 *         UFragments 0.4.24 token). Deposit v1 to mint a fixed wrapper
 *         balance; burn the wrapper to withdraw v1. Locked v1 is never
 *         burned — it stays in this contract.
 *
 * @dev This is a two-way alternative to `LeashMigrator` / the fixed-supply
 *      `LeashV2` burn-and-swap design. It is modeled on Ampleforth WAMPL:
 *      each wrapper token is a *proportional share* of the current v1
 *      `totalSupply()`, not a 1:1 "equivalent amount" of v1.
 *
 *      Conversion (live `v1.totalSupply()` every call, never stored):
 *          wrapped    = mulDiv(v1Amount, MAX_WRAPPED, v1.totalSupply())
 *          underlying = mulDiv(wrappedAmount, v1.totalSupply(), MAX_WRAPPED)
 *      using 512-bit `mulDiv`. `MAX_WRAPPED` is 107,646.4693 tokens (18
 *      decimals), the wrapper amount you would hold if *all* v1 were
 *      wrapped. The cap is reached only in that case.
 *
 *      Rounding always favours this contract:
 *        - `deposit` / `depositFor` mint `floor` wrapper for the v1
 *          actually received (balance delta, so v1 gon rounding cannot
 *          over-credit the depositor);
 *        - `mint` / `mintFor` pull `ceil` of the required v1 for the
 *          requested wrapper amount;
 *        - `withdraw` / `withdrawTo` burn `ceil` wrapper for the requested
 *          v1 out;
 *        - `burn` / `burnTo` / `burnAll` / `withdrawAll` pay `floor` v1
 *          for the wrapper burned.
 *      Zero amounts (including conversions that floor to zero) revert.
 *
 *      There is no owner, admin, pause, tax, blacklist, or mint path
 *      other than depositing v1. There is no EIP-2612 `permit`; use
 *      `approve` (and `increaseAllowance` / `decreaseAllowance`).
 *
 *      Why a v1 rebase does not change a wrapper holder's *share*:
 *      a rebase scales every v1 balance, including the v1 locked here,
 *      by the same factor. Wrapper balances do not change. A holder of
 *      `W` wrapper tokens is always entitled to `W / MAX_WRAPPED` of
 *      current `v1.totalSupply()`. The pie can grow or shrink; the
 *      slice does not. Example at the live v1 supply of
 *      803,760,032,105,055,242.245609937123889209 LEASH
 *      (803760032105055242245609937123889209 base units): depositing
 *      100 v1 mints 13392861 wei of LEASH V2
 *      (0.000000000013392861 tokens) — a proportional share, not 100
 *      wrapper tokens. After a 2x rebase, that wrapper balance is
 *      unchanged and unwraps for ~200 v1.
 *
 *      Verified on Ethereum, 22 Nov 2026:
 *        - v1 `owner()` is the zero address (renounced);
 *        - EIP-1967 implementation, admin, and beacon slots are empty,
 *          and the token account holds the full UFragments runtime
 *          (it is not a proxy and is not upgradeable);
 *        - rebases are still triggered through the v1 monetary policy
 *          (`0xEff020b07a292baad7A948897c87F99e4Fe6636B`). Its market
 *          oracle (`0x8a920C8565783c3aE4aA236e92A5227c4A3eeDcB`) still
 *          has a non-zero owner (`0x01e0C58EebE0e8B8435458B191a9bb049DC5c50b`)
 *          and a single provider (`0x44539732152752EA9568E69440BFB910B0d474b5`).
 *      Those keys can still move the v1 unit supply; they cannot mint
 *      wrapper tokens, seize locked v1, or change a holder's share.
 *
 *      Leftover wei from rounding (and any v1 donated directly to this
 *      contract) stays here as extra backing. There is no admin recovery.
 *      `totalUnderlying()` is the redeemable amount
 *      `wrapperToUnderlying(totalSupply())`, which may be slightly less
 *      than `v1.balanceOf(address(this))`.
 */
contract WrappedLeash {
    // ---------------------------------------------------------------------
    // Token metadata. Default ERC-20 name/symbol are "LEASH V2" / "LEASH".
    // Alternative labels are kept as constants for announcements and
    // integrations; change `name` / `symbol` if you want a different title.
    // ---------------------------------------------------------------------
    string public constant name = "LEASH V2";
    string public constant symbol = "LEASH";
    string public constant NAME_LEASH = "LEASH";
    string public constant NAME_WRAPPED_LEASH = "Wrapped LEASH";
    uint8 public constant decimals = 18;

    /// @notice Wrapper amount outstanding if the entire v1 supply is wrapped.
    uint256 public constant MAX_WRAPPED = 107646.4693e18;

    /// @notice Ethereum mainnet address of legacy LEASH v1.
    address public constant MAINNET_V1 = 0x27C70Cd1946795B66be9d954418546998b546634;

    IUnderlying private immutable _v1;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    bool private _entered;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Emitted when v1 is locked and wrapper tokens are minted.
    event Deposit(address indexed from, address indexed to, uint256 underlyingAmount, uint256 wrappedAmount);

    /// @notice Emitted when wrapper tokens are burned and v1 is released.
    event Withdraw(address indexed from, address indexed to, uint256 underlyingAmount, uint256 wrappedAmount);

    modifier nonReentrant() {
        require(!_entered, "WrappedLeash: reentrant");
        _entered = true;
        _;
        _entered = false;
    }

    /**
     * @param v1_ Legacy LEASH v1 token. On mainnet this is `MAINNET_V1`.
     *            Must have a non-zero `totalSupply()` at deploy.
     */
    constructor(address v1_) {
        require(v1_ != address(0), "WrappedLeash: zero underlying");
        require(IUnderlying(v1_).totalSupply() != 0, "WrappedLeash: v1 supply is zero");
        _v1 = IUnderlying(v1_);
    }

    // ---------------------------------------------------------------------
    // Wrap / unwrap (WAMPL-style)
    // ---------------------------------------------------------------------

    /**
     * @notice Deposit `uAmount` of v1 from the caller and mint wrapper tokens
     *         to the caller. Mints `floor` of the conversion on the v1
     *         actually received.
     * @return wAmount Wrapper tokens minted.
     */
    function deposit(uint256 uAmount) external nonReentrant returns (uint256 wAmount) {
        wAmount = _deposit(msg.sender, msg.sender, uAmount);
    }

    /**
     * @notice Deposit `uAmount` of v1 from the caller and mint wrapper tokens
     *         to `to`.
     * @return wAmount Wrapper tokens minted.
     */
    function depositFor(address to, uint256 uAmount) external nonReentrant returns (uint256 wAmount) {
        wAmount = _deposit(msg.sender, to, uAmount);
    }

    /**
     * @notice Pull enough v1 from the caller (rounded up) to mint exactly
     *         `wAmount` wrapper tokens to the caller.
     * @return uAmount v1 pulled (the ceiled requirement).
     */
    function mint(uint256 wAmount) external nonReentrant returns (uint256 uAmount) {
        uAmount = _mintFor(msg.sender, msg.sender, wAmount);
    }

    /**
     * @notice Pull enough v1 from the caller (rounded up) to mint exactly
     *         `wAmount` wrapper tokens to `to`.
     * @return uAmount v1 pulled (the ceiled requirement).
     */
    function mintFor(address to, uint256 wAmount) external nonReentrant returns (uint256 uAmount) {
        uAmount = _mintFor(msg.sender, to, wAmount);
    }

    /**
     * @notice Burn enough wrapper tokens from the caller (rounded up) to
     *         withdraw exactly `uAmount` of v1 to the caller.
     * @return wAmount Wrapper tokens burned.
     */
    function withdraw(uint256 uAmount) external nonReentrant returns (uint256 wAmount) {
        wAmount = _withdrawUnderlying(msg.sender, msg.sender, uAmount);
    }

    /**
     * @notice Burn enough wrapper tokens from the caller (rounded up) to
     *         withdraw exactly `uAmount` of v1 to `to`.
     * @return wAmount Wrapper tokens burned.
     */
    function withdrawTo(address to, uint256 uAmount) external nonReentrant returns (uint256 wAmount) {
        wAmount = _withdrawUnderlying(msg.sender, to, uAmount);
    }

    /**
     * @notice Burn the caller's entire wrapper balance and send the floored
     *         v1 proceeds to the caller.
     * @return wAmount Wrapper tokens burned (the caller's full balance).
     */
    function withdrawAll() external nonReentrant returns (uint256 wAmount) {
        wAmount = _burnAll(msg.sender, msg.sender);
    }

    /**
     * @notice Burn the caller's entire wrapper balance and send the floored
     *         v1 proceeds to `to`.
     * @return wAmount Wrapper tokens burned (the caller's full balance).
     */
    function withdrawAllTo(address to) external nonReentrant returns (uint256 wAmount) {
        wAmount = _burnAll(msg.sender, to);
    }

    /**
     * @notice Burn `wAmount` wrapper tokens from the caller and send the
     *         floored v1 proceeds to the caller.
     * @return uAmount v1 sent.
     */
    function burn(uint256 wAmount) external nonReentrant returns (uint256 uAmount) {
        uAmount = _burnTo(msg.sender, msg.sender, wAmount);
    }

    /**
     * @notice Burn `wAmount` wrapper tokens from the caller and send the
     *         floored v1 proceeds to `to`.
     * @return uAmount v1 sent.
     */
    function burnTo(address to, uint256 wAmount) external nonReentrant returns (uint256 uAmount) {
        uAmount = _burnTo(msg.sender, to, wAmount);
    }

    /**
     * @notice Burn the caller's entire wrapper balance and send the floored
     *         v1 proceeds to the caller.
     * @return uAmount v1 sent.
     */
    function burnAll() external nonReentrant returns (uint256 uAmount) {
        uint256 wAmount = _balances[msg.sender];
        uAmount = _burnTo(msg.sender, msg.sender, wAmount);
    }

    /**
     * @notice Burn the caller's entire wrapper balance and send the floored
     *         v1 proceeds to `to`.
     * @return uAmount v1 sent.
     */
    function burnAllTo(address to) external nonReentrant returns (uint256 uAmount) {
        uint256 wAmount = _balances[msg.sender];
        uAmount = _burnTo(msg.sender, to, wAmount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @return The address of the underlying v1 token.
    function underlying() external view returns (address) {
        return address(_v1);
    }

    /// @return The v1 redeemable for the entire wrapper supply (floored).
    ///         May be slightly less than the v1 actually held here.
    function totalUnderlying() external view returns (uint256) {
        return _wrapperToUnderlyingDown(_totalSupply, _v1Supply());
    }

    /// @param account The wrapper holder.
    /// @return The v1 redeemable by `account` (floored).
    function balanceOfUnderlying(address account) external view returns (uint256) {
        return _wrapperToUnderlyingDown(_balances[account], _v1Supply());
    }

    /// @notice Wrapper minted for a `deposit` of `uAmount` v1 (floored).
    function underlyingToWrapper(uint256 uAmount) external view returns (uint256) {
        return _underlyingToWrapperDown(uAmount, _v1Supply());
    }

    /// @notice v1 paid out for a `burn` of `wAmount` wrapper (floored).
    function wrapperToUnderlying(uint256 wAmount) external view returns (uint256) {
        return _wrapperToUnderlyingDown(wAmount, _v1Supply());
    }

    // ---------------------------------------------------------------------
    // ERC-20
    // ---------------------------------------------------------------------

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        require(allowed >= value, "WrappedLeash: insufficient allowance");
        _allowances[from][msg.sender] = allowed - value;
        _transfer(from, to, value);
        return true;
    }

    /**
     * @notice Increase the allowance granted to `spender` by `addedValue`.
     */
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        uint256 newAllowance = _allowances[msg.sender][spender] + addedValue;
        _allowances[msg.sender][spender] = newAllowance;
        emit Approval(msg.sender, spender, newAllowance);
        return true;
    }

    /**
     * @notice Decrease the allowance granted to `spender` by `subtractedValue`.
     * @dev If `subtractedValue` is greater than or equal to the current
     *      allowance, the allowance is set to zero rather than reverting.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 oldValue = _allowances[msg.sender][spender];
        uint256 newAllowance = subtractedValue >= oldValue ? 0 : oldValue - subtractedValue;
        _allowances[msg.sender][spender] = newAllowance;
        emit Approval(msg.sender, spender, newAllowance);
        return true;
    }

    // ---------------------------------------------------------------------
    // Internal wrap / unwrap
    // ---------------------------------------------------------------------

    function _deposit(address from, address to, uint256 uAmount) private returns (uint256 wAmount) {
        require(uAmount != 0, "WrappedLeash: zero amount");
        _requireRecipient(to);
        uint256 received = _pullUnderlying(from, uAmount);
        wAmount = _underlyingToWrapperDown(received, _v1Supply());
        require(wAmount != 0, "WrappedLeash: zero wrapped");
        _mintWrapped(to, wAmount);
        emit Deposit(from, to, received, wAmount);
    }

    function _mintFor(address from, address to, uint256 wAmount) private returns (uint256 uAmount) {
        require(wAmount != 0, "WrappedLeash: zero amount");
        _requireRecipient(to);
        uAmount = _wrapperToUnderlyingUp(wAmount, _v1Supply());
        require(uAmount != 0, "WrappedLeash: zero underlying");
        uint256 received = _pullUnderlying(from, uAmount);
        require(received >= uAmount, "WrappedLeash: insufficient received");
        _mintWrapped(to, wAmount);
        emit Deposit(from, to, received, wAmount);
    }

    function _withdrawUnderlying(address from, address to, uint256 uAmount) private returns (uint256 wAmount) {
        require(uAmount != 0, "WrappedLeash: zero amount");
        _requireRecipient(to);
        wAmount = _underlyingToWrapperUp(uAmount, _v1Supply());
        require(wAmount != 0, "WrappedLeash: zero wrapped");
        _burnWrapped(from, wAmount);
        _pushUnderlying(to, uAmount);
        emit Withdraw(from, to, uAmount, wAmount);
    }

    function _burnTo(address from, address to, uint256 wAmount) private returns (uint256 uAmount) {
        require(wAmount != 0, "WrappedLeash: zero amount");
        _requireRecipient(to);
        uAmount = _wrapperToUnderlyingDown(wAmount, _v1Supply());
        require(uAmount != 0, "WrappedLeash: zero underlying");
        _burnWrapped(from, wAmount);
        _pushUnderlying(to, uAmount);
        emit Withdraw(from, to, uAmount, wAmount);
    }

    function _burnAll(address from, address to) private returns (uint256 wAmount) {
        wAmount = _balances[from];
        _burnTo(from, to, wAmount);
    }

    function _pullUnderlying(address from, uint256 uAmount) private returns (uint256 received) {
        uint256 before = _v1.balanceOf(address(this));
        require(_v1.transferFrom(from, address(this), uAmount), "WrappedLeash: v1 transfer failed");
        received = _v1.balanceOf(address(this)) - before;
        require(received != 0, "WrappedLeash: zero received");
    }

    function _pushUnderlying(address to, uint256 uAmount) private {
        require(_v1.transfer(to, uAmount), "WrappedLeash: v1 transfer failed");
    }

    function _mintWrapped(address to, uint256 wAmount) private {
        uint256 newSupply = _totalSupply + wAmount;
        require(newSupply <= MAX_WRAPPED, "WrappedLeash: cap exceeded");
        _totalSupply = newSupply;
        _balances[to] += wAmount;
        emit Transfer(address(0), to, wAmount);
    }

    function _burnWrapped(address from, uint256 wAmount) private {
        uint256 bal = _balances[from];
        require(bal >= wAmount, "WrappedLeash: insufficient balance");
        _balances[from] = bal - wAmount;
        _totalSupply -= wAmount;
        emit Transfer(from, address(0), wAmount);
    }

    function _transfer(address from, address to, uint256 value) private {
        require(to != address(0), "WrappedLeash: transfer to the zero address");
        uint256 bal = _balances[from];
        require(bal >= value, "WrappedLeash: insufficient balance");
        _balances[from] = bal - value;
        _balances[to] += value;
        emit Transfer(from, to, value);
    }

    function _requireRecipient(address to) private view {
        require(to != address(0) && to != address(this), "WrappedLeash: invalid recipient");
    }

    function _v1Supply() private view returns (uint256 supply) {
        supply = _v1.totalSupply();
        require(supply != 0, "WrappedLeash: v1 supply is zero");
    }

    function _underlyingToWrapperDown(uint256 uAmount, uint256 v1Supply) private pure returns (uint256) {
        return _mulDiv(uAmount, MAX_WRAPPED, v1Supply);
    }

    function _underlyingToWrapperUp(uint256 uAmount, uint256 v1Supply) private pure returns (uint256) {
        return _mulDivUp(uAmount, MAX_WRAPPED, v1Supply);
    }

    function _wrapperToUnderlyingDown(uint256 wAmount, uint256 v1Supply) private pure returns (uint256) {
        return _mulDiv(wAmount, v1Supply, MAX_WRAPPED);
    }

    function _wrapperToUnderlyingUp(uint256 wAmount, uint256 v1Supply) private pure returns (uint256) {
        return _mulDivUp(wAmount, v1Supply, MAX_WRAPPED);
    }

    /**
     * @notice `floor(x * y / d)` with 512-bit intermediate precision.
     *         Reverts if `d == 0` or the result does not fit in a `uint256`.
     * @dev Algorithm from OpenZeppelin Contracts `Math.mulDiv` (MIT license).
     */
    function _mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0 = x * y;
            uint256 prod1;
            assembly {
                let mm := mulmod(x, y, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                require(d != 0, "WrappedLeash: div by zero");
                return prod0 / d;
            }

            require(d > prod1, "WrappedLeash: mulDiv overflow");

            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = d & (0 - d);
            assembly {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }

            prod0 |= prod1 * twos;

            uint256 inverse = (3 * d) ^ 2;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;

            result = prod0 * inverse;
        }
    }

    /**
     * @notice `ceil(x * y / d)` with 512-bit intermediate precision.
     */
    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        result = _mulDiv(x, y, d);
        if (mulmod(x, y, d) != 0) {
            require(result < type(uint256).max, "WrappedLeash: mulDiv overflow");
            unchecked {
                result += 1;
            }
        }
    }
}
