// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title  LiquidityPool
/// @notice 50-50 AMM with constant-product formula (x·y = k) and a fixed 0.3 % fee,
///         inspired by Uniswap V2. Liquidity providers receive LP-tokens
///         representing their proportional share of the reserves.
/// @dev    The contract inherits from `ERC20Burnable` so that LP-tokens can be burned
///         when liquidity is withdrawn.
contract LiquidityPool is ERC20Burnable {
    /*───────────────────────  State variables  ───────────────────────*/

    /// @notice First token of the pair.
    IERC20 public immutable token0;

    /// @notice Second token of the pair.
    IERC20 public immutable token1;

    /// @notice Current reserves of `token0`, keeping 18 decimals.
    uint112 private reserve0;

    /// @notice Current reserves of `token1`, keeping 18 decimals.
    uint112 private reserve1;

    /*────────────────────────────  Events  ──────────────────────────────*/

    /// @notice Emitted after each successful swap.
    /// @param sender     Caller of the function.
    /// @param amountIn0  Amount of `token0` that entered the swap.
    /// @param amountIn1  Amount of `token1` that entered the swap.
    /// @param amountOut0 Amount of `token0` sent to the recipient.
    /// @param amountOut1 Amount of `token1` sent to the recipient.
    /// @param to         Address that received the output tokens.
    event Swap(
        address indexed sender,
        uint amountIn0,
        uint amountIn1,
        uint amountOut0,
        uint amountOut1,
        address indexed to
    );

    /// @notice Emitted whenever the reserves change.
    /// @param r0 New reserve of `token0`.
    /// @param r1 New reserve of `token1`.
    event Sync(uint112 r0, uint112 r1);

    /*───────────────────────  Constructor  ───────────────────────────────*/

    /// @param _t0 Address of the first token.
    /// @param _t1 Address of the second token.
    /// @dev  Prohibits identical pairs and sets the LP-token’s name/symbol.
    constructor(address _t0, address _t1) ERC20("LP-Token", "LPT") {
        require(_t0 != _t1, "identical");
        token0 = IERC20(_t0);
        token1 = IERC20(_t1);
    }

    /*──────────────────────  Liquidity management  ───────────────────────*/

    /// @notice Deposits both tokens and mints LP-tokens to the caller.
    /// @param a0 Amount of `token0` to deposit.
    /// @param a1 Amount of `token1` to deposit.
    /// @return lp Amount of LP-tokens minted.
    function addLiquidity(uint a0, uint a1) external returns (uint lp) {
        // Transfers the tokens to the pool.
        token0.transferFrom(msg.sender, address(this), a0);
        token1.transferFrom(msg.sender, address(this), a1);

        // Calculate the LP-tokens to mint.
        lp = totalSupply() == 0
            ? _sqrt(a0 * a1) // first provision
            : _min(
                (a0 * totalSupply()) / reserve0, // keep ratio
                (a1 * totalSupply()) / reserve1
            );
        require(lp > 0, "no LP");

        _mint(msg.sender, lp); // deliver LP-tokens
        (uint b0, uint b1) = _getBalances();
        _update(b0, b1); // sync reserves
    }

    /// @notice Removes liquidity by burning LP-tokens and returning the
    ///         corresponding reserves.
    /// @param lp Amount of LP-tokens to burn.
    /// @return a0 Amount of `token0` withdrawn.
    /// @return a1 Amount of `token1` withdrawn.
    function removeLiquidity(uint lp) external returns (uint a0, uint a1) {
        uint supply = totalSupply();
        (uint b0, uint b1) = _getBalances();

        // Exact proportion to withdraw.
        a0 = (lp * b0) / supply;
        a1 = (lp * b1) / supply;
        require(a0 > 0 && a1 > 0, "low");

        _burn(msg.sender, lp); // burn LP-tokens

        // Send the tokens back to the provider.
        token0.transfer(msg.sender, a0);
        token1.transfer(msg.sender, a1);

        (b0, b1) = _getBalances();
        _update(b0, b1);
    }

    /*──────────────────────────────  Swap  ───────────────────────────────*/

    /// @notice Swaps tokens while respecting the invariant x·y = k and charging
    ///         a 0.3 % fee (997/1000).
    /// @param a0Out Amount of `token0` desired to receive.
    /// @param a1Out Amount of `token1` desired to receive.
    /// @param to    Address that will receive the output tokens.
    function swap(uint a0Out, uint a1Out, address to) external {
        require(a0Out > 0 || a1Out > 0, "zero-out"); // there must be output
        require(a0Out < reserve0 && a1Out < reserve1, "no liq"); // sufficient liquidity

        // Optimistically send the outputs.
        if (a0Out > 0) token0.transfer(to, a0Out);
        if (a1Out > 0) token1.transfer(to, a1Out);

        // Post-transfer balance.
        (uint b0, uint b1) = _getBalances();

        // Calculate effective inputs (lazy evaluation).
        uint a0In = b0 > reserve0 - a0Out ? b0 - (reserve0 - a0Out) : 0;
        uint a1In = b1 > reserve1 - a1Out ? b1 - (reserve1 - a1Out) : 0;
        require(a0In > 0 || a1In > 0, "no in"); // something must have come in

        /* Check invariant:
         *   (b0*1000 - a0In*3) * (b1*1000 - a1In*3) ≥ reserve0*reserve1*1000²
         * This is equivalent to applying a 0.3 % fee to the inputs and requiring
         * that k does not decrease.
         */
        uint bal0Adj = b0 * 1000 - a0In * 3;
        uint bal1Adj = b1 * 1000 - a1In * 3;
        require(
            bal0Adj * bal1Adj >= uint(reserve0) * reserve1 * 1_000_000,
            "k"
        );

        _update(b0, b1); // update reserves
        emit Swap(msg.sender, a0In, a1In, a0Out, a1Out, to);
    }

    /*──────────────────  Internal functions / Utils  ───────────────────*/

    /// @dev Returns the current balances of both tokens held by this contract.
    /// @return b0 Balance of token0.
    /// @return b1 Balance of token1.
    function _getBalances() private view returns (uint b0, uint b1) {
        b0 = token0.balanceOf(address(this));
        b1 = token1.balanceOf(address(this));
    }

    /// @dev Updates the reserves and emits `Sync`.
    function _update(uint b0, uint b1) private {
        reserve0 = uint112(b0);
        reserve1 = uint112(b1);
        emit Sync(reserve0, reserve1);
    }

    /// @dev Integer square root using the Babylonian method.
    ///      Used for the first liquidity provision (lp = √(a0·a1)).
    function _sqrt(uint y) internal pure returns (uint z) {
        unchecked {
            if (y > 3) {
                z = y;
                uint x = y / 2 + 1;
                while (x < z) {
                    z = x;
                    x = (y / x + x) / 2;
                }
            } else if (y != 0) {
                z = 1; // √1…3 = 1
            }
        }
    }

    /// @dev Returns the minimum of two integers.
    function _min(uint a, uint b) private pure returns (uint) {
        return a < b ? a : b;
    }
}
