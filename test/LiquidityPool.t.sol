// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*──────────────────────── IMPORTS ────────────────────────*/
// forge-std/Test.sol ⇒ Foundry’s library that exposes testing utilities
// and the “cheatcodes” available through the global `vm` variable.
import "forge-std/Test.sol";
import "../src/LiquidityPool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/*──────────────────── TEST TOKEN ────────────────────*/
/**
 * @title  TestToken
 * @notice Minimal ERC-20 meant only for the testing environment.
 *         — The constructor sets the name and symbol.
 *         — The `mint()` function allows unrestricted minting
 *           (should NOT be used like this in production).
 */
contract TestToken is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    /// @dev Mints `amount` tokens to the recipient `to`.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/*────────────────── TEST SUITE ──────────────────*/
/**
 * @title  LiquidityPoolTest
 * @notice Unit-test set to verify the public functions of `LiquidityPool`.
 *         Inherits from `Test`, giving access to:
 *         - `assertEq`, `expectRevert`, etc.     (assertions)
 *         - `vm` (cheatcodes) to manipulate the EVM during tests
 *           (pranks, deals, warps, fork, etc.).
 */
contract LiquidityPoolTest is Test {
    /*──────────── STATE VARIABLES (FIXTURE) ───────────*/
    TestToken token0; // First token of the pair
    TestToken token1; // Second token of the pair
    LiquidityPool pool; // AMM under test

    // Dummy addresses; make the trace logs easier to read.
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    /*───────────── UTILITY: sqrt() ─────────────*/
    /// @dev Internal integer square root: used to compute the reference
    ///      value we expect from the first liquidity provision
    ///      (LP = √(a0·a1)).
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    /*───────────── GLOBAL FIXTURE ─────────────*/
    /**
     * @notice setUp() runs before **each** test.
     *         It prepares the local chain with:
     *         1. Two fresh ERC-20 tokens.
     *         2. A deployed LiquidityPool contract.
     *         3. Initial balances (1 000 000 tokens) for Alice and Bob.
     *         4. Infinite approvals from both toward the pool.
     *
     *         Cheatcodes used:
     *         - `vm.startPrank(addr)`   ⇒ all subsequent txs are signed
     *                                    as `addr` until `vm.stopPrank()`.
     *         - `vm.stopPrank()`        ⇒ ends the impersonation.
     */
    function setUp() public {
        // 1) Deploy tokens
        token0 = new TestToken("Token0", "TK0");
        token1 = new TestToken("Token1", "TK1");

        // 2) Deploy the pool with the two tokens
        pool = new LiquidityPool(address(token0), address(token1));

        // 3) Mint large balances for the actors
        uint256 BIG = 1_000_000 ether; // 1 million tokens
        token0.mint(ALICE, BIG);
        token1.mint(ALICE, BIG);
        token0.mint(BOB, BIG);
        token1.mint(BOB, BIG);

        // 4) Alice signs approvals ⇒ the pool may move her tokens
        vm.startPrank(ALICE);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        //    Bob does the same
        vm.startPrank(BOB);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    /*─────────────────── TEST 1 ───────────────────*/
    /**
     * @dev Verifies that the **first** liquidity provision mints
     *      exactly √(a0·a1) LP-tokens and assigns them to the provider.
     *      Steps:
     *      1. Alice adds 1 000 TK0 + 4 000 TK1.
     *      2. Compare:
     *         - LP issued vs. theoretical value.
     *         - LP-token totalSupply.
     *         - Alice’s LP balance.
     *
     * Cheatcodes:
     * - `vm.prank(ALICE)` ⇒ the next call is signed as Alice.
     *
     * Assertions (`assertEq`):
     * - Strict equality; revert with message if it fails.
     */
    function testInitialLiquidityMintsSqrt() public {
        uint256 amt0 = 1_000 ether;
        uint256 amt1 = 4_000 ether;

        vm.prank(ALICE); // next tx ≡ Alice
        uint256 lpMinted = pool.addLiquidity(amt0, amt1); // action under test

        uint256 expected = _sqrt(amt0 * amt1); // theoretical value
        assertEq(lpMinted, expected, "Incorrect LP mint");
        assertEq(pool.totalSupply(), expected, "Unexpected totalSupply");
        assertEq(pool.balanceOf(ALICE), expected, "Wrong Alice LP balance");
    }

    /*─────────────────── TEST 2 ───────────────────*/
    /**
     * @dev Checks that adding liquidity in the **same ratio**
     *      does not change the price and mints LP-tokens linearly.
     *      1. Alice creates pool 1 000/1 000.
     *      2. Store supply before.
     *      3. Bob adds 500/500 ⇒ expect +500 LP.
     */
    function testAddLiquidityKeepsRatio() public {
        vm.prank(ALICE);
        pool.addLiquidity(1_000 ether, 1_000 ether); // base state
        uint256 supplyBefore = pool.totalSupply();

        vm.prank(BOB);
        pool.addLiquidity(500 ether, 500 ether); // same ratio
        uint256 supplyAfter = pool.totalSupply();

        assertEq(supplyAfter, supplyBefore + 500 ether, "Unexpected LP mint");
    }

    /*─────────────────── TEST 3 ───────────────────*/
    /**
     * @dev Verifies that `removeLiquidity`:
     *      - Burns the correct amount of LP-tokens.
     *      - Returns the proportional underlying tokens.
     *      - Updates the pool’s reserves.
     *
     * Steps:
     *  1. Alice adds 1 000/1 000.
     *  2. Store her LP balance.
     *  3. Withdraw half (lp/2) ⇒ pool should hold 500/500.
     */
    function testRemoveLiquidityReturnsAssets() public {
        vm.prank(ALICE);
        pool.addLiquidity(1_000 ether, 1_000 ether);

        uint256 lpAlice = pool.balanceOf(ALICE); // LP issued

        vm.prank(ALICE);
        pool.removeLiquidity(lpAlice / 2); // withdraw 50 %

        // ─── Assertions ───
        assertEq(pool.balanceOf(ALICE), lpAlice / 2, "Remaining LP incorrect");
        assertEq(
            token0.balanceOf(address(pool)),
            500 ether,
            "Reserve TK0 mismatch"
        );
        assertEq(
            token1.balanceOf(address(pool)),
            500 ether,
            "Reserve TK1 mismatch"
        );
    }

    /*─────────────────── TEST 4 ───────────────────*/
    /**
     * @dev Tests the `swap` function:
     *      1. A symmetric pool 1 000/1 000 is created.
     *      2. Bob sends 100 TK0 and asks for 90 TK1 (expected result).
     *      3. Confirm Bob receives an extra 90 TK1.
     *
     * Cheatcodes:
     *  - `vm.startPrank(BOB)` / `vm.stopPrank()` ⇒ multiple txs in a row as Bob.
     */
    function testSwapToken0ForToken1() public {
        vm.prank(ALICE);
        pool.addLiquidity(1_000 ether, 1_000 ether);

        uint256 bobTk1Before = token1.balanceOf(BOB);

        vm.startPrank(BOB); // tx block as Bob
        token0.transfer(address(pool), 100 ether); // input
        pool.swap(0, 90 ether, BOB); // output
        vm.stopPrank();

        assertEq(
            token1.balanceOf(BOB),
            bobTk1Before + 90 ether,
            "Bob did not receive 90 TK1"
        );
    }

    /*─────────────────── TEST 5 ───────────────────*/
    /**
     * @dev Ensures that `swap` reverts if both output parameters are zero.
     *      We use `vm.expectRevert("zero-out")` to anticipate the exact revert.
     */
    function testSwapRevertsZeroOut() public {
        vm.prank(ALICE);
        pool.addLiquidity(1_000 ether, 1_000 ether);

        vm.expectRevert("zero-out"); // expect revert
        vm.prank(BOB);
        pool.swap(0, 0, BOB); // call that must fail
    }

    /*─────────────────── NEW NEGATIVE-PATH TESTS ──────────────────*/

    /**
     * @dev Ensures the constructor reverts when both token addresses are identical.
     *
     * Steps:
     *  1. We do not deploy a pool in `setUp()` here; we attempt to deploy a new
     *     LiquidityPool passing the *same* address twice.
     *
     * Cheatcodes:
     *  - `vm.expectRevert(bytes("identical"))` → instructs the test runner to
     *    expect a revert whose reason string is exactly "identical".
     *
     * Assertion:
     *  - The test passes automatically if the revert matches; otherwise it fails.
     */
    function testConstructorRevertsIdenticalTokens() public {
        vm.expectRevert(bytes("identical"));
        new LiquidityPool(address(token0), address(token0));
    }

    /**
     * @dev Verifies that `addLiquidity` reverts with “no LP” when the calculated
     *      share (`lp`) is zero (extremely unbalanced ratio).
     *
     * Scenario:
     *  1. A valid pool with 1 000/1 000 is created (base state).
     *  2. Bob tries to deposit **1 TK0 / 0 TK1** — ratio is off, lp = 0.
     *
     * Cheatcodes:
     *  - `vm.prank(ALICE)` / `vm.prank(BOB)` to sign calls as the actors.
     *  - `vm.expectRevert(bytes("no LP"))` to capture the revert.
     */
    function testAddLiquidityRevertsNoLP() public {
        vm.prank(ALICE);
        pool.addLiquidity(1_000 ether, 1_000 ether); // initial liquidity

        vm.prank(BOB);
        vm.expectRevert(bytes("no LP"));
        pool.addLiquidity(1 ether, 0); // lp would be zero
    }

    /**
     * @dev Checks that `swap` reverts with “no liq” when the requested output
     *      exceeds the pool’s reserves.
     *
     * Steps:
     *  1. Pool reserves: 100 / 100.
     *  2. Bob asks for 101 TK0 out — more than is available.
     */
    function testSwapRevertsNoLiquidity() public {
        vm.prank(ALICE);
        pool.addLiquidity(100 ether, 100 ether);

        vm.prank(BOB);
        vm.expectRevert(bytes("no liq"));
        pool.swap(101 ether, 0, BOB); // a0Out > reserve0
    }

    /**
     * @dev Ensures `swap` reverts with “no in” when no token input is provided
     *      (caller tries to take out value for free).
     *
     * Flow:
     *  1. Pool has 100 / 100.
     *  2. Bob provides **0** input but requests 1 TK1 out.
     */
    function testSwapRevertsNoInput() public {
        vm.prank(ALICE);
        pool.addLiquidity(100 ether, 100 ether);

        vm.prank(BOB);
        vm.expectRevert(bytes("no in"));
        pool.swap(0, 1 ether, BOB); // asks output w/ no input
    }

    /**
     * @dev Validates that `swap` reverts with “k” when the constant-product
     *      invariant would be broken.
     *
     * Procedure:
     *  1. Pool reserves start at 1 000 / 1 000.
     *  2. Bob sends only 1 TK0 in but tries to withdraw 990 TK1 out → violates k.
     *
     * Cheatcodes:
     *  - `vm.startPrank` / `vm.stopPrank` for multiple calls as Bob.
     */
    function testSwapRevertsInvariantK() public {
        vm.prank(ALICE);
        pool.addLiquidity(1_000 ether, 1_000 ether);

        vm.startPrank(BOB);
        token0.transfer(address(pool), 1 ether); // tiny input
        vm.expectRevert(bytes("k"));
        pool.swap(0, 990 ether, BOB); // breaks invariant
        vm.stopPrank();
    }

    /**
     * @dev Confirms that *tiny* symmetric deposits trigger the `sqrt` branch and
     *      mint exactly 1 wei of LP-token.
     *
     * Expectations:
     *  - For (1 wei, 1 wei) the geometric mean √(1·1) equals 1, so lp = 1.
     */
    function testAddLiquidityTinyAmountsMintsOneLP() public {
        vm.prank(ALICE);
        uint256 lp = pool.addLiquidity(1, 1); // 1 wei each token
        assertEq(lp, 1, "LP should be 1 wei");
    }
}
