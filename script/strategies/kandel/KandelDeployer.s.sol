// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Kandel} from "mgv_src/strategies/offer_maker/market_making/kandel/Kandel.sol";
import {MgvStructs} from "mgv_src/MgvLib.sol";
import {IMangrove} from "mgv_src/IMangrove.sol";
import {IERC20} from "mgv_src/IERC20.sol";
import {Deployer} from "mgv_script/lib/Deployer.sol";
import {MangroveTest, Test} from "mgv_test/lib/MangroveTest.sol";

/**
 * @notice deploys a Kandel instance on a given market
 * @dev since the max number of price slot Kandel can use is an immutable, one should deploy Kandel on a large price range.
 * @dev Example: WRITE_DEPLOY=true BASE=WETH QUOTE=USDC GASPRICE_FACTOR=10 COMPOUND_RATE_BASE=100 COMPOUND_RATE_QUOTE=100 forge script --fork-url $LOCALHOST_URL KandelDeployer --broadcast --private-key $MUMBAI_PRIVATE_KEY
 */

contract KandelDeployer is Deployer {
  Kandel public current;

  function run() public {
    innerRun({
      base: envAddressOrName("BASE"),
      quote: envAddressOrName("QUOTE"),
      gaspriceFactor: vm.envUint("GASPRICE_FACTOR"), // 10 means cover 10x the current gasprice of Mangrove
      compoundRateBase: vm.envUint("COMPOUND_RATE_BASE"), // in percent
      compoundRateQuote: vm.envUint("COMPOUND_RATE_QUOTE"), // in percent
      gasreq: 160_000
    });
    outputDeployment();
  }

  /**
   * @param base Address of the base token of the market Kandel will act on
   * @param quote Address of the quote token of the market Kandel will act on
   * @param gasreq the gas required for the offer logic
   * @param gaspriceFactor multiplier of Mangrove's gasprice used to compute Kandel's provision
   * @param compoundRateBase <= 10**4, the proportion of the spread Kandel will reinvest automatically for base
   * @param compoundRateQuote <= 10**4, the proportion of the spread Kandel will reinvest automatically for quote
   */
  function innerRun(
    address base,
    address quote,
    uint gasreq,
    uint gaspriceFactor,
    uint compoundRateBase,
    uint compoundRateQuote
  ) public {
    IMangrove mgv = IMangrove(fork.get("Mangrove"));
    (MgvStructs.GlobalPacked global,) = mgv.config(address(0), address(0));

    broadcast();
    current = new Kandel(
      mgv,
      IERC20(base),
      IERC20(quote),
      gasreq,
      global.gasprice() * gaspriceFactor,
      broadcaster()
    );

    uint precision = current.PRECISION();
    broadcast();
    current.setCompoundRates(compoundRateBase * 10 ** (precision - 2), compoundRateQuote * 10 ** (precision - 2));

    string memory kandelName = getName(IERC20(base), IERC20(quote));
    fork.set(kandelName, address(current));
  }

  function getName(IERC20 base, IERC20 quote) public view returns (string memory) {
    try vm.envString("NAME") returns (string memory name) {
      return name;
    } catch {
      return string.concat("Kandel_", base.symbol(), "_", quote.symbol());
    }
  }
}
