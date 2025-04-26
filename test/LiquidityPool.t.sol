// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*──────────────────────── IMPORTS ────────────────────────*/
// forge-std/Test.sol => biblioteca de Foundry que expone utilidades
// de test y los “cheatcodes” accesibles a través de la variable global `vm`.
import "forge-std/Test.sol";
import "../src/LiquidityPool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/*──────────────────── TOKEN DE PRUEBA ────────────────────*/
/**
 * @title  TestToken
 * @notice ERC-20 mínimo pensado solo para el entorno de pruebas.
 *         — El constructor define nombre y símbolo.
 *         — La función `mint()` permite acuñar tokens sin restricción
 *           (no habría que usarla así en producción).
 */
contract TestToken is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    /// @dev Acuña `amount` tokens al destinatario `to`.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/*────────────────── SUITE DE PRUEBAS ───────────────────*/
/**
 * @title  LiquidityPoolTest
 * @notice Conjunto unitario para verificar las funciones públicas de
 *         `LiquidityPool`.  Hereda de `Test`, que nos da acceso a:
 *         - `assertEq`, `expectRevert`, etc.    (aserciones)
 *         - `vm` (cheatcodes) para manipular el EVM durante los tests
 *           (pranks, deals, warps, fork, etc.).
 */
contract LiquidityPoolTest is Test {
    /*──────────── VARIABLES DE ESTADO (FIXTURE) ───────────*/
    TestToken token0; // Primer token del par
    TestToken token1; // Segundo token del par
    LiquidityPool pool; // AMM que vamos a testear

    // Direcciones ficticias; facilitan la lectura de los trace logs.
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    /*───────────── UTILIDAD: sqrt() ─────────────*/
    /// @dev Versión interna de la raíz cuadrada entera: la usamos para
    ///      calcular el valor de referencia que esperamos de la primera
    ///      provisión de liquidez (LP = √(a0·a1)).
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

    /*───────────── FIXTURE GLOBAL ─────────────*/
    /**
     * @notice setUp() se ejecuta antes de **cada** test.
     *         Prepara la red local con:
     *         1. Dos tokens ERC-20 frescos.
     *         2. Un contrato LiquidityPool desplegado.
     *         3. Saldos iniciales (1 000 000 tokens) para Alice y Bob.
     *         4. Aprobaciones infinitas de ambos hacia el pool.
     *
     *         Cheatcodes utilizados:
     *         - `vm.startPrank(addr)`   ⇒ todas las tx siguientes se firman
     *                                    como `addr` hasta `vm.stopPrank()`.
     *         - `vm.stopPrank()`        ⇒ finaliza el “impersonation”.
     */
    function setUp() public {
        // 1) Despliegue de tokens
        token0 = new TestToken("Token0", "TK0");
        token1 = new TestToken("Token1", "TK1");

        // 2) Despliegue del pool con los dos tokens
        pool = new LiquidityPool(address(token0), address(token1));

        // 3) Acuñar balances grandes para los actores
        uint256 BIG = 1_000_000 ether; // 1 millón de tokens
        token0.mint(ALICE, BIG);
        token1.mint(ALICE, BIG);
        token0.mint(BOB, BIG);
        token1.mint(BOB, BIG);

        // 4) Alice firma aprobaciones => el pool podrá mover sus tokens
        vm.startPrank(ALICE);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        //    Bob hace lo mismo
        vm.startPrank(BOB);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    /*─────────────────── TEST 1 ───────────────────*/
    /**
     * @dev Verifica que la **primera** provisión de liquidez acuñe
     *      exactamente √(a0·a1) LP-tokens y los asigne al proveedor.
     *      Pasos:
     *      1. Alice añade 1 000 TK0 + 4 000 TK1.
     *      2. Comparamos:
     *         - LP emitidos vs valor teórico.
     *         - totalSupply del LP-token.
     *         - balance LP de Alice.
     *
     * Cheatcodes:
     * - `vm.prank(ALICE)` ⇒ la próxima llamada se firma como Alice.
     *
     * Aserciones (`assertEq`):
     * - Comprueban igualdad estricta; si falla, revert con mensaje.
     */
    function testInitialLiquidityMintsSqrt() public {
        uint256 amt0 = 1_000 ether;
        uint256 amt1 = 4_000 ether;

        vm.prank(ALICE); // siguiente tx ≡ Alice
        uint256 lpMinted = pool.addLiquidity(amt0, amt1); // acción bajo test

        uint256 expected = _sqrt(amt0 * amt1); // valor teórico
        assertEq(lpMinted, expected, "Incorrect LP mint");
        assertEq(pool.totalSupply(), expected, "Unexpected totalSupply");
        assertEq(pool.balanceOf(ALICE), expected, "Wrong Alice LP balance");
    }

    /*─────────────────── TEST 2 ───────────────────*/
    /**
     * @dev Comprueba que añadir liquidez en la **misma proporción**
     *      no cambie el precio y emita LP-tokens linealmente.
     *      1. Alice crea pool 1 000/1 000.
     *      2. Guardamos supply antes.
     *      3. Bob añade 500/500 ⇒ esperamos +500 LP.
     */
    function testAddLiquidityKeepsRatio() public {
        vm.prank(ALICE);
        pool.addLiquidity(1_000 ether, 1_000 ether); // estado base
        uint256 supplyBefore = pool.totalSupply();

        vm.prank(BOB);
        pool.addLiquidity(500 ether, 500 ether); // misma proporción
        uint256 supplyAfter = pool.totalSupply();

        assertEq(supplyAfter, supplyBefore + 500 ether, "Unexpected LP mint");
    }

    /*─────────────────── TEST 3 ───────────────────*/
    /**
     * @dev Verifica que `removeLiquidity`:
     *      - Quema la cantidad correcta de LP-tokens.
     *      - Devuelve los tokens subyacentes proporcionales.
     *      - Actualiza las reservas del pool.
     *
     * Pasos:
     *  1. Alice añade 1 000/1 000.
     *  2. Guarda su balance LP.
     *  3. Retira la mitad (lp/2) ⇒ deberían quedar 500/500 en el pool.
     */
    function testRemoveLiquidityReturnsAssets() public {
        vm.prank(ALICE);
        pool.addLiquidity(1_000 ether, 1_000 ether);

        uint256 lpAlice = pool.balanceOf(ALICE); // LP emitidos

        vm.prank(ALICE);
        pool.removeLiquidity(lpAlice / 2); // retira el 50 %

        // ─── Aserciones ───
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
     * @dev Testea la función `swap`:
     *      1. Se crea pool simétrico 1 000/1 000.
     *      2. Bob envía 100 TK0 y pide 90 TK1 (resultado esperado).
     *      3. Confirmamos que Bob recibe 90 TK1 adicionales.
     *
     * Cheatcodes:
     *  - `vm.startPrank(BOB)` / `vm.stopPrank()` ⇒ varias tx seguidas como Bob.
     */
    function testSwapToken0ForToken1() public {
        vm.prank(ALICE);
        pool.addLiquidity(1_000 ether, 1_000 ether);

        uint256 bobTk1Before = token1.balanceOf(BOB);

        vm.startPrank(BOB); // bloque de tx como Bob
        token0.transfer(address(pool), 100 ether); // aporta input
        pool.swap(0, 90 ether, BOB); // recibe output
        vm.stopPrank();

        assertEq(
            token1.balanceOf(BOB),
            bobTk1Before + 90 ether,
            "Bob did not receive 90 TK1"
        );
    }

    /*─────────────────── TEST 5 ───────────────────*/
    /**
     * @dev Asegura que `swap` revierte si ambos parámetros de salida son cero.
     *      Utilizamos `vm.expectRevert("zero-out")` para anticipar el revert exacto.
     */
    function testSwapRevertsZeroOut() public {
        vm.prank(ALICE);
        pool.addLiquidity(1_000 ether, 1_000 ether);

        vm.expectRevert("zero-out"); // esperamos revert
        vm.prank(BOB);
        pool.swap(0, 0, BOB); // call que debe fallar
    }
}
