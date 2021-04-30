// SPDX-License-Identifier: MIT
/*

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

	// breaking some constants out here, getting stack ;) issues

	// CRV FUNCTIONS
	/*
		CRV Notes:
			add_liquidity takes a fixed size array of input, so it will change the function signature
			0x0b4c7e4d --> 2 coin pool --> add_liquidity(uint256[2] uamounts, uint256 min_mint_amount)
			0x4515cef3 --> 3 coin pool --> add_liquidity(uint256[3] amounts, uint256 min_mint_amount)
			0x029b2f34 --> 4 coin pool --> add_liquidity(uint256[4] amounts, uint256 min_mint_amount)

			0xee22be23 --> 2 coin pool underlying --> add_liquidity(uint256[2] _amounts, uint256 _min_mint_amount, bool _use_underlying)
			0x2b6e993a -> 3 coin pool underlying --> add_liquidity(uint256[3] _amounts, uint256 _min_mint_amount, bool _use_underlying)

			remove_liquidity_one_coin has an optional end argument, bool donate_dust

			0x517a55a3 --> remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 min_uamount, bool donate_dust)
			0x1a4d01d2 --> remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 min_amount)

			remove_liquidity_imbalance takes a fixes array of input too
			0x18a7bd76 --> 4 coin pool --> remove_liquidity_imbalance(uint256[4] amounts, uint256 max_burn_amount)
	*/

	bytes4 constant private add_liquidity_u_3 = 0x2b6e993a;

	bytes4 constant private remove_liquidity_one_burn = 0x517a55a3;
	bytes4 constant private remove_liquidity_one = 0x1a4d01d2;

	bytes4 constant private remove_liquidity_3 = 0x5b8369f5;

	bytes4 constant private deposit_gauge = 0xb6b55f25; // deposit(uint256 _value)
	bytes4 constant private withdraw_gauge = 0x2e1a7d4d; // withdraw(uint256 _value)

	bytes4 constant private claim_rewards = 0x84e9bd7e; // claim_rewards(address addr)

	constructor(address payable _governance, address _daoMultisig, address _treasury, address _underlying) public FarmBossV1_MATIC(_governance, _daoMultisig, _treasury, _underlying){
	}

	function _initFirstFarms() internal override {

		/*
			For MATIC USDC, we initially only have the 1 Curve.fi -> Aave pool, get good base from Aave and liquidate MATIC token rewards.
		*/

		////////////// ALLOW CURVE //////////////

		////////////// ALLOW crvAave Pool //////////////
		address _crvAavePool = 0x445FE580eF8d70FF569aB36e80c647af338db351; // new style lending pool w/o second approve needed... direct burn from msg.sender
		address _crvAaveToken = 0xE7a24EF0C5e95Ffb0f6684b813A78F2a3AD7D171; 
		_approveMax(underlying, _crvAavePool);
		_addWhitelist(_crvAavePool, add_liquidity_u_3, false);
		_addWhitelist(_crvAavePool, remove_liquidity_one_burn, false);
		_addWhitelist(_crvAavePool, remove_liquidity_3, false);

		////////////// ALLOW crvAave Gauge //////////////
		address _crvAaveGauge = 0xe381C25de995d62b453aF8B931aAc84fcCaa7A62;
		_approveMax(_crvAaveToken, _crvAaveGauge);
		_addWhitelist(_crvAaveGauge, deposit_gauge, false);
		_addWhitelist(_crvAaveGauge, withdraw_gauge, false);
		_addWhitelist(_crvAaveGauge, claim_rewards, false); // claim WMATIC rewards

		address _WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270; // Wrapped Matic, usually rewards token

		_approveMax(_WMATIC, SushiswapRouter);
		_approveMax(_WMATIC, UniswapRouter);

		////////////// END ALLOW CURVE //////////////
	}
}