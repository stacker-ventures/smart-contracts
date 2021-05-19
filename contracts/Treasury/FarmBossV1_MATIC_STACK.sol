// SPDX-License-Identifier: MIT
/*
	For the STACK vault on MATIC, we send buyback funds to the account on MATIC, in USDC, WBTC, WETH. Also we send STACK direcly as a bonus for the first year.

	The USDC,WBTC,WETH is sold on Sushi/Quick for more STACK. All this (+ bonus) is declared as profit each month.
*/

pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol"; // call ERC20 safely
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./FarmBossV1_MATIC.sol";

contract FarmBossV1_MATIC_USDC is FarmBossV1_MATIC {
	using SafeERC20 for IERC20;
	using SafeMath for uint256;
	using Address for address;


	constructor(address payable _governance, address _daoMultisig, address _treasury, address _underlying) public FarmBossV1_MATIC(_governance, _daoMultisig, _treasury, _underlying){
	}

	function _initFirstFarms() internal override {

		// MATIC PoS bridged addresses
		address _WBTC = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;
		address _WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
		address _USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;

		_approveMax(_WBTC, SushiswapRouter);
		_approveMax(_WBTC, UniswapRouter);

		_approveMax(_WETH, SushiswapRouter);
		_approveMax(_WETH, UniswapRouter);

		_approveMax(_USDC, SushiswapRouter);
		_approveMax(_USDC, UniswapRouter);
	}
}