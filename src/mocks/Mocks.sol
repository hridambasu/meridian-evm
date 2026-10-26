// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOracle} from "../interfaces/IMeridian.sol";
import {ISwapper} from "../periphery/FlashLiquidator.sol";

/// @notice Test / local-devnet token with public mint.
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _dec = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Settable 1e36-scaled price, for tests and local demos.
contract MockOracle is IOracle {
    uint256 public price;

    constructor(uint256 initialPrice) {
        price = initialPrice;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }
}

/// @notice Chainlink-style feed for adapter tests.
contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        answer = _answer;
        updatedAt = block.timestamp;
    }

    function set(int256 _answer, uint256 _updatedAt) external {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice DEX stand-in: swaps at an oracle price minus a configurable slippage,
/// minting the output token. Lets the local keeper demo full flash liquidations.
contract MockSwapper is ISwapper {
    IOracle public oracle; // price of tokenIn in tokenOut, 1e36 scaled
    uint256 public slippageBps;

    constructor(IOracle _oracle, uint256 _slippageBps) {
        oracle = _oracle;
        slippageBps = _slippageBps;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address receiver)
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn * oracle.price() / 1e36 * (10_000 - slippageBps) / 10_000;
        require(amountOut >= minAmountOut, "slippage");
        MockERC20(tokenOut).mint(receiver, amountOut);
    }
}
