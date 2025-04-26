// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title  LiquidityPool
/// @notice AMM 50-50 con fórmula de producto constante (x·y = k) y comisión fija del 0,3 %,
///         inspirado en Uniswap V2.  Los proveedores de liquidez reciben LP-tokens
///         que representan su participación proporcional en las reservas.
/// @dev    El contrato hereda de `ERC20Burnable` para que los LP-tokens puedan quemarse
///         al retirar liquidez.
contract LiquidityPool is ERC20Burnable {
    /*───────────────────────  Variables de estado  ───────────────────────*/

    /// @notice Primer token del par.
    IERC20 public immutable token0;

    /// @notice Segundo token del par.
    IERC20 public immutable token1;

    /// @notice Reservas actuales de `token0` manteniendo 18 decimales.
    uint112 private reserve0;

    /// @notice Reservas actuales de `token1` manteniendo 18 decimales.
    uint112 private reserve1;

    /*────────────────────────────  Eventos  ──────────────────────────────*/

    /// @notice Emitted after each successful swap.
    /// @param sender    Llamador de la función.
    /// @param amountIn0 Cantidad de `token0` que entró en la operación.
    /// @param amountIn1 Cantidad de `token1` que entró en la operación.
    /// @param amountOut0 Cantidad de `token0` enviada al receptor.
    /// @param amountOut1 Cantidad de `token1` enviada al receptor.
    /// @param to        Dirección que recibió los tokens de salida.
    event Swap(
        address indexed sender,
        uint amountIn0,
        uint amountIn1,
        uint amountOut0,
        uint amountOut1,
        address indexed to
    );

    /// @notice Emitter whenever las reservas cambian.
    /// @param r0 Nueva reserva de `token0`.
    /// @param r1 Nueva reserva de `token1`.
    event Sync(uint112 r0, uint112 r1);

    /*───────────────────────  Constructor  ───────────────────────────────*/

    /// @param _t0 Dirección del primer token.
    /// @param _t1 Dirección del segundo token.
    /// @dev  Prohibe pares idénticos y acuña el símbolo/nombre del LP-token.
    constructor(address _t0, address _t1) ERC20("LP-Token", "LPT") {
        require(_t0 != _t1, "identical");
        token0 = IERC20(_t0);
        token1 = IERC20(_t1);
    }

    /*──────────────────────  Gestión de Liquidez  ───────────────────────*/

    /// @notice Deposita ambos tokens y acuña LP-tokens al llamador.
    /// @param a0 Monto de `token0` a depositar.
    /// @param a1 Monto de `token1` a depositar.
    /// @return lp Cantidad de LP-tokens acuñados.
    function addLiquidity(uint a0, uint a1) external returns (uint lp) {
        // Transfiere los tokens al pool.
        token0.transferFrom(msg.sender, address(this), a0);
        token1.transferFrom(msg.sender, address(this), a1);

        // Cálculo de LP-tokens a acuñar.
        lp = totalSupply() == 0
            ? _sqrt(a0 * a1) // primera provisión
            : _min(
                (a0 * totalSupply()) / reserve0, // mantiene la proporción
                (a1 * totalSupply()) / reserve1
            );
        require(lp > 0, "no LP");

        _mint(msg.sender, lp); // entrega LP-tokens
        _update(
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this))
        ); // sincroniza reservas
    }

    /// @notice Quita liquidez quemando LP-tokens y devolviendo las reservas
    ///         correspondientes.
    /// @param lp Cantidad de LP-tokens a quemar.
    /// @return a0 Cantidad de `token0` retirada.
    /// @return a1 Cantidad de `token1` retirada.
    function removeLiquidity(uint lp) external returns (uint a0, uint a1) {
        uint supply = totalSupply();
        uint b0 = token0.balanceOf(address(this));
        uint b1 = token1.balanceOf(address(this));

        // Proporción exacta a retirar.
        a0 = (lp * b0) / totalSupply();
        a1 = (lp * b1) / totalSupply();
        require(a0 > 0 && a1 > 0, "low");

        _burn(msg.sender, lp); // quema LP-tokens

        // Envía los tokens al proveedor.
        token0.transfer(msg.sender, a0);
        token1.transfer(msg.sender, a1);

        _update(
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this))
        );
    }

    /*──────────────────────────────  Swap  ───────────────────────────────*/

    /// @notice Intercambia tokens respetando la invariante x·y = k y cobrando
    ///         un 0,3 % de comisión (997/1000).
    /// @param a0Out Cantidad de `token0` deseada a recibir.
    /// @param a1Out Cantidad de `token1` deseada a recibir.
    /// @param to    Dirección receptora de los tokens de salida.
    function swap(uint a0Out, uint a1Out, address to) external {
        require(a0Out > 0 || a1Out > 0, "zero-out"); // debe haber salida
        require(a0Out < reserve0 && a1Out < reserve1, "no liq"); // hay liquidez suficiente

        // Envía salidas optimísticamente.
        if (a0Out > 0) token0.transfer(to, a0Out);
        if (a1Out > 0) token1.transfer(to, a1Out);

        // Saldo post-transferencia.
        uint b0 = token0.balanceOf(address(this));
        uint b1 = token1.balanceOf(address(this));

        // Calcula entradas efectivas (lazy-evaluation).
        uint a0In = b0 > reserve0 - a0Out ? b0 - (reserve0 - a0Out) : 0;
        uint a1In = b1 > reserve1 - a1Out ? b1 - (reserve1 - a1Out) : 0;
        require(a0In > 0 || a1In > 0, "no in"); // se debió recibir algo

        /* Verifica invariante:
         *   (b0*1000 - a0In*3) * (b1*1000 - a1In*3) ≥ reserve0*reserve1*1000²
         * Es equivalente a aplicar fee 0,3 % a las entradas y exigir
         * que k no disminuya.
         */
        uint bal0Adj = b0 * 1000 - a0In * 3;
        uint bal1Adj = b1 * 1000 - a1In * 3;
        require(
            bal0Adj * bal1Adj >= uint(reserve0) * reserve1 * 1_000_000,
            "k"
        );

        _update(b0, b1); // actualiza reservas
        emit Swap(msg.sender, a0In, a1In, a0Out, a1Out, to);
    }

    /*──────────────────  Funciones internas / Utils  ───────────────────*/

    /// @dev Actualiza las reservas y emite `Sync`.
    function _update(uint b0, uint b1) private {
        reserve0 = uint112(b0);
        reserve1 = uint112(b1);
        emit Sync(reserve0, reserve1);
    }

    /// @dev Raíz cuadrada entera mediante el método babilónico.
    ///      Usada para la primera provisión de liquidez (lp = √(a0·a1)).
    function _sqrt(uint y) private pure returns (uint z) {
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

    /// @dev Devuelve el mínimo de dos enteros.
    function _min(uint a, uint b) private pure returns (uint) {
        return a < b ? a : b;
    }
}
