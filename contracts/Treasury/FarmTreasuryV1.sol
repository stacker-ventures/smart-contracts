// SPDX-License-Identifier: MIT
/*
This is a Stacker.vc FarmTreasury version 1 contract. It deploys a rebase token where it rebases to be equivalent to it's underlying token. 1 stackUSDT = 1 USDT.
The underlying assets are used to farm on different smart contract and produce yield via the ever-expanding DeFi ecosystem.

THANKS! To Lido DAO for the inspiration in more ways than one, but especially for a lot of the code here. 
If you haven't already, stake your ETH for ETH2.0 with Lido.fi!

Also thanks for Aragon for hosting our Stacker Ventures DAO, and for more inspiration!
*/

pragma solidity ^0.6.11;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol"; // call ERC20 safely
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./FarmTokenV1.sol";

contract FarmTreasuryV1 is ReentrancyGuard, FarmTokenV1 {
	using SafeERC20 for IERC20;
	using SafeMath for uint256;
	using Address for address;

	mapping(address => DepositInfo) userDeposits;

	struct DepositInfo {
		uint256 amountUnderlyingLocked;
		uint256 timestampDeposit;
		uint256 timestampUnlocked;
	}

	address payable public governance;
	address payable public farmBoss;

	bool public paused = false;
	bool public pausedDeposits = false;

	// fee schedule, can be changed by governance, in bips
	// performance fee is on any gains, base fee is on AUM/yearly
	uint256 public constant max = 10000;
	uint256 public performanceToTreasury = 1000;
	uint256 public performanceToFarmer = 1000;
	uint256 public baseToTreasury = 100;
	uint256 public baseToFarmer = 100;
	uint256 public lastAnnualFeeTime;

	// limits on rebalancing from the farmer, trying to negate errant rebalances
	uint256 public rebalanceUpLimit = 150; // maximum of a 1.5% gain per rebalance
	uint256 public rebalanceUpWaitTime = 6 hours;
	uint256 public lastRebalanceUpTime;

	// waiting period on withdraws from time of deposit
	// locked amount linearly decreases until the time is up, so at waitPeriod/2 after deposit, you can withdraw depositAmt/2 funds.
	uint256 public waitPeriod = 2 weeks;

	// hot wallet holdings for instant withdraw, in bips
	// if the hot wallet balance expires, the users will need to wait for the next rebalance period in order to withdraw
	uint256 public hotWalletHoldings = 1000; // 10% initially

	uint256 public ACTIVELY_FARMED;

	event FailedRebalance(string reason);
	event Rebalance(uint256 amountIn, uint256 amountToFarmer, uint256 timestamp);
	event Deposit(address depositor, uint256 amount, address referral);
	event Withdraw(address withdrawer, uint256 amount);

	constructor(string memory _nameUnderlying, uint8 _decimalsUnderlying, address _underlying) public FarmTokenV1(_nameUnderlying, _decimalsUnderlying, _underlying) {
		governance = msg.sender;

		lastAnnualFeeTime = block.timestamp.add(7 days); // start taking the annual fee in the future, after a week
	}

	function setGovernance(address payable _new) external {
		require(msg.sender == governance, "FARMTREASURYV1: !governance");
		governance = _new;
	}

	// the "farmBoss" is a trusted smart contract that functions kind of like an EOA.
	// HOWEVER specific contract addresses need to be whitelisted in order for this contract to be allowed to interact w/ them
	// the governance has full control over the farmBoss, and other addresses can have partial control for strategy rotation/rebalancing
	function setFarmBoss(address payable _new) external {
		require(msg.sender == governance, "FARMTREASURYV1: !governance");
		farmBoss = _new;
	}

	function pause() external {
		require(msg.sender == governance, "FARMTREASURYV1: !governance");
		paused = true;
	}

	function unpause() external {
		require(msg.sender == governance, "FARMTREASURYV1: !governance");
		paused = false;
	}

	function pauseDeposits() external {
		require(msg.sender == governance, "FARMTREASURYV1: !governance");
		pausedDeposits = true;
	}

	function unpauseDeposits() external {
		require(msg.sender == governance, "FARMTREASURYV1: !governance");
		pausedDeposits = false;
	}

	function setFeeDistribution(uint256 _performanceToTreasury, uint256 _performanceToFarmer, uint256 _baseToTreasury, uint256 _baseToFarmer) external {
		require(msg.sender == governance, "FARMTREASURYV1: !governance");
		require(_performanceToTreasury.add(_performanceToFarmer) < max, "FARMTREASURYV1: too high performance");
		require(_baseToTreasury.add(_baseToFarmer) <= 500, "FARMTREASURYV1: too high base");
		
		performanceToTreasury = _performanceToTreasury;
		performanceToFarmer = _performanceToFarmer;
		baseToTreasury = _baseToTreasury;
		baseToFarmer = _baseToFarmer;
	}

	function setWaitPeriod(uint256 _new) external {
		require(msg.sender == governance, "FARMTREASURYV1: !governance");
		require(_new <= 5 weeks, "FARMTREASURYV1: too long wait");

		waitPeriod = _new;
	}

	function setHotWalletHoldings(uint256 _new) external {
		require(msg.sender == governance, "FARMTREASURYV1: !governance");
		require(_new <= max && _new >= 100, "FARMTREASURYV1: hot wallet values bad");

		hotWalletHoldings = _new;
	}

	function setRebalanceUpLimit(uint256 _new) external {
		require(msg.sender == governance, "FARMTREASURYV1: !governance");
		require(_new < max, "FARMTREASURYV1: >= max");

		rebalanceUpLimit = _new;
	}

	function setRebalanceUpWaitTime(uint256 _new) external {
		require(msg.sender == governance, "FARMTREASURYV1: !governance");
		require(_new <= 1 weeks, "FARMTREASURYV1: !governance");

		rebalanceUpWaitTime = _new;
	}

	function deposit(uint256 _amountUnderlying, address _referral) external nonReentrant {
		require(_amountUnderlying > 0, "FARMTREASURYV1: amount == 0");
		require(!paused && !pausedDeposits, "FARMTREASURYV1: paused");

		// paused logic
		// deposits paused, but other functions live

		// determine how many shares this will be
		uint256 _sharesToMint = getSharesForUnderlying(_amountUnderlying);

		uint256 _before = IERC20(underlyingContract).balanceOf(address(this));
		IERC20(underlyingContract).safeTransferFrom(msg.sender, address(this), _amountUnderlying);
		uint256 _after = IERC20(underlyingContract).balanceOf(address(this));
		uint256 _total = _after.sub(_before);
		require(_total >= _amountUnderlying, "FARMTREASURYV1: bad transfer");

		_mintShares(msg.sender, _sharesToMint);
		emit Transfer(address(0), msg.sender, _amountUnderlying);
		emit Deposit(msg.sender, _amountUnderlying, _referral);

		// store some important info for this deposit, that will be checked on withdraw/transfer of tokens
		_storeDepositInfo(msg.sender, _amountUnderlying);
	}

	function _storeDepositInfo(address _account, uint256 _amountUnderlying) internal {

		DepositInfo memory _existingInfo = userDeposits[_account];

		// first deposit, make a new entry in the mapping, lock all funds for "waitPeriod"
		if (_existingInfo.timestampDeposit == 0){
			DepositInfo memory _info = DepositInfo(
				{
					amountUnderlyingLocked: _amountUnderlying, 
					timestampDeposit: block.timestamp, 
					timestampUnlocked: block.timestamp.add(waitPeriod)
				}
			);
			userDeposits[_account] = _info;
		}
		// not the first deposit, if there are still funds locked, then average out the waits (ie: 1 BTC locked 10 days = 2 BTC locked 5 days)
		else {
			uint256 _lockedAmt = _getLockedAmount(_existingInfo.amountUnderlyingLocked, _existingInfo.timestampDeposit, _existingInfo.timestampUnlocked);
			// if there's no lock, disregard old info and make a new lock

			if (_lockedAmt == 0){
				DepositInfo memory _info = DepositInfo(
					{
						amountUnderlyingLocked: _amountUnderlying, 
						timestampDeposit: block.timestamp, 
						timestampUnlocked: block.timestamp.add(waitPeriod)
					}
				);
				userDeposits[_account] = _info;
			}
			// funds are still locked from a past deposit, average out the waittime remaining with the waittime for this new deposit
			/*
				solve this equation:

				newDepositAmt * waitPeriod + remainingAmt * existingWaitPeriod = (newDepositAmt + remainingAmt) * X waitPeriod

				therefore:

								(newDepositAmt * waitPeriod + remainingAmt * existingWaitPeriod)
				X waitPeriod =  ----------------------------------------------------------------
												(newDepositAmt + remainingAmt)

				Example: 7 BTC new deposit, with wait period of 2 weeks
						 1 BTC remaining, with remaining wait period of 1 week
						 ...
						 (7 BTC * 2 weeks + 1 BTC * 1 week) / 8 BTC = 1.875 weeks

			*/
			else {
				uint256 _lockedAmtTime = _lockedAmt.mul(_existingInfo.timestampUnlocked.sub(block.timestamp));
				uint256 _newAmtTime = _amountUnderlying.mul(waitPeriod);
				uint256 _total = _amountUnderlying.add(_lockedAmt);

				uint256 _newLockedTime = (_lockedAmtTime.add(_newAmtTime)).div(_total);

				DepositInfo memory _info = DepositInfo(
					{
						amountUnderlyingLocked: _total, 
						timestampDeposit: block.timestamp, 
						timestampUnlocked: _newLockedTime
					}
				);
				userDeposits[_account] = _info;
			}
		}
	}

	function getLockedAmount(address _account) public view returns (uint256) {
		DepositInfo memory _existingInfo = userDeposits[_account];
		return _getLockedAmount(_existingInfo.amountUnderlyingLocked, _existingInfo.timestampDeposit, _existingInfo.timestampUnlocked);

	}

	// the locked amount linearly decreases until the timestampUnlocked time, then it's zero
	// Example: if 5 BTC contributed (2 week lock), then after 1 week there will be 2.5 BTC locked, the rest is free to transfer/withdraw
	function _getLockedAmount(uint256 _amountLocked, uint256 _timestampDeposit, uint256 _timestampUnlocked) internal view returns (uint256) {
		if (_timestampUnlocked <= block.timestamp){
			return 0;
		}
		else {
			uint256 _remainingTime = _timestampUnlocked.sub(block.timestamp);
			uint256 _totalTime = _timestampUnlocked.sub(_timestampDeposit);

			return _amountLocked.mul(_remainingTime).div(_totalTime);
		}
	}

	function withdraw(uint256 _amountUnderlying) external nonReentrant {
		require(_amountUnderlying > 0, "FARMTREASURYV1: amount == 0");
		require(!paused, "FARMTREASURYV1: paused");

		_verify(msg.sender, _amountUnderlying);

		uint256 _sharesToBurn = getSharesForUnderlying(_amountUnderlying);

		_burnShares(msg.sender, _sharesToBurn); // this checks that they have this balance
		
		IERC20(underlyingContract).safeTransfer(msg.sender, _amountUnderlying);

		emit Transfer(msg.sender, address(0), _amountUnderlying);
		emit Withdraw(msg.sender, _amountUnderlying);
	}

	function _verify(address _account, uint256 _amountUnderlyingToSend) internal override {
		// wait time logic
		// cannot withdraw/transfer same block as deposit (timestamp would be equal)
		require(userDeposits[_account].timestampDeposit != block.timestamp, "FARMTREASURYV1: deposit this block");

		uint256 _lockedAmt = getLockedAmount(_account);
		uint256 _balance = balanceOf(_account);

		// require that any funds locked are not leaving the account in question.
		require(_balance.sub(_amountUnderlyingToSend) >= _lockedAmt, "FARMTREASURYV1: requested funds are temporarily locked");
	}

	// this means that we made a GAIN, due to standard farming gains
	// operaratable by farmBoss, this is standard operating procedure, farmers can only report gains
	function rebalanceUp(uint256 _amount, address _farmerRewards) external nonReentrant {
		require(msg.sender == farmBoss, "FARMTREASURYV1: !farmBoss");
		require(!paused, "FARMTREASURYV1: paused");

		// check the farmer limits on rebalance waits & amount that was earned from farming
		require(block.timestamp.sub(lastRebalanceUpTime) >= rebalanceUpWaitTime, "FARMTREASURYV1: <rebalanceUpWaitTime");
		require(ACTIVELY_FARMED.mul(rebalanceUpLimit).div(max) >= _amount, "FARMTREASURYV1 _amount > rebalanceUpLimit");

		// farmer incurred a gain of _amount, add this to the amount being farmed
		ACTIVELY_FARMED = ACTIVELY_FARMED.add(_amount);

		// assess fee
		// to mint the required amount of fee shares, solve:
		/* 
			ratio:

			    	currentShares 			  newShares		
			-------------------------- : --------------------, where newShares = (currentShares + mintShares)
			(totalUnderlying - feeAmt) 		totalUnderlying

			solved:

			(currentShares / (totalUnderlying - feeAmt) * totalUnderlying) - currentShares = newShares, where newBalanceLessFee = (totalUnderlying - feeAmt)

			OR:

			--> (currentShares * totalUnderlying / newBalanceLessFee) - currentShares = newShares
		*/

		uint256 _existingShares = totalShares;
		uint256 _newBalance = IERC20(underlyingContract).balanceOf(address(this)).add(ACTIVELY_FARMED);

		uint256 _performanceToFarmer = performanceToFarmer;
		uint256 _performanceToTreasury = performanceToTreasury;
		uint256 _performanceTotal = _performanceToFarmer.add(_performanceToTreasury);

		uint256 _performanceUnderlying = _amount.mul(_performanceTotal).div(max);
		uint _newBalanceLessFee = _newBalance.sub(_performanceUnderlying);

		uint256 _newShares = _existingShares
								.mul(_newBalance)
								.div(_newBalanceLessFee)
								.sub(_existingShares);

		uint256 _sharesToFarmer = _newShares.mul(_performanceToFarmer).div(_performanceTotal);
		uint256 _sharesToTreasury = _newShares.mul(_performanceToTreasury).div(_performanceTotal);

		_mintShares(_farmerRewards, _sharesToFarmer);
		_mintShares(governance, _sharesToTreasury);

		// do two mint events, in underlying, not shares
		emit Transfer(address(0), _farmerRewards, getUnderlyingForShares(_sharesToFarmer));
		emit Transfer(address(0), governance, getUnderlyingForShares(_sharesToTreasury));

		// end fee assessment

		

		// start annual fee logic
		_annualFee(_farmerRewards);
		// end annual fee logic

		// funds are in the contract and gains are accounted for, now determine if we need to further rebalance the hot wallet up, or can take funds in order to farm
		// start hot wallet and farmBoss rebalance logic
		(bool _fundsNeeded, uint256 _amountChange) = _calcHotWallet();
		_rebalanceHot(_fundsNeeded, _amountChange);
		// if the hot wallet rebalance fails, revert() the entire function

		lastRebalanceUpTime = block.timestamp;
		// end logic
	}

	// this means that the system took a loss, and it needs to be reflected in the next rebalance
	// only operatable by governance, (large) losses should be extremely rare by good farming practices
	// this would not be a loss from ImpLoss-strategies, but from a farmed smart contract getting exploited/hacked, and us not having the necessary insurance for it
	function rebalanceDown(uint256 _amount, bool _rebalanceHotWallet) external nonReentrant {
		require(msg.sender == governance, "FARMTREASURYV1: !governance");
		// require(!paused, "FARMTREASURYV1: paused"); <-- governance can only call this anyways, leave this commented out

		ACTIVELY_FARMED = ACTIVELY_FARMED.sub(_amount);

		if (_rebalanceHotWallet){
			(bool _fundsNeeded, uint256 _amountChange) = _calcHotWallet();
			_rebalanceHot(_fundsNeeded, _amountChange);
			// if the hot wallet rebalance fails, revert() the entire function
		}
	}

	// we are taking baseToTreasury + baseToFarmer each year, every time this is called, look when we took fee last, and linearize the fee to now();
	function _annualFee(address _farmerRewards) internal {
		uint256 _lastAnnualFeeTime = lastAnnualFeeTime;

		// for the first week, we don't take a fee, so just return on this initial case
		if (_lastAnnualFeeTime >= block.timestamp){
			return;
		}

		uint256 _elapsedTime = _lastAnnualFeeTime.sub(block.timestamp);

		uint256 _sharesPossibleFee = totalShares.mul(_elapsedTime).div(365 days);
		lastAnnualFeeTime = block.timestamp; // set to now, fee will be taken ^

		uint256 _sharesFeeToFarmer = _sharesPossibleFee.mul(baseToFarmer).div(max);
		uint256 _sharesFeeToTreasury = _sharesPossibleFee.mul(baseToTreasury).div(max);

		_mintShares(_farmerRewards, _sharesFeeToFarmer);
		_mintShares(governance, _sharesFeeToTreasury);

		// two mint events, converting underlying to shares
		emit Transfer(address(0), _farmerRewards, getUnderlyingForShares(_sharesFeeToFarmer));
		emit Transfer(address(0), governance, getUnderlyingForShares(_sharesFeeToTreasury));
	}

	function _calcHotWallet() internal view returns (bool _fundsNeeded, uint256 _amountChange) {
		uint256 _balanceHere = IERC20(underlyingContract).balanceOf(address(this));
		uint256 _balanceFarmed = ACTIVELY_FARMED;

		uint256 _totalAmount = _balanceHere.add(_balanceFarmed);
		uint256 _hotAmount = _totalAmount.mul(hotWalletHoldings).div(max);

		// we have too much in hot wallet, send to farmBoss
		if (_balanceHere >= _hotAmount){
			return (false, _balanceHere.sub(_hotAmount));
		}
		// we have too little in hot wallet, pull from farmBoss
		if (_balanceHere < _hotAmount){
			return (true, _hotAmount.sub(_balanceHere));
		}
	}

	// usually paired with _calcHotWallet()
	function _rebalanceHot(bool _fundsNeeded, uint256 _amountChange) internal {
		if (_fundsNeeded){
			uint256 _before = IERC20(underlyingContract).balanceOf(address(this));
			IERC20(underlyingContract).safeTransferFrom(farmBoss, address(this), _amountChange);
			uint256 _after = IERC20(underlyingContract).balanceOf(address(this));
			uint256 _total = _after.sub(_before);

			require(_total >= _amountChange, "FARMTREASURYV1: bad rebalance, hot wallet needs funds!");

			// we took funds from the farmBoss to refill the hot wallet, reflect this in ACTIVELY_FARMED
			ACTIVELY_FARMED = ACTIVELY_FARMED.sub(_total);

			emit Rebalance(_amountChange, 0, block.timestamp);
		}
		else {
			require(farmBoss != address(0), "FARMTREASURYV1: !FarmBoss"); // don't burn funds

			uint256 _before = IERC20(underlyingContract).balanceOf(farmBoss);
			IERC20(underlyingContract).safeTransfer(farmBoss, _amountChange); // _calcHotWallet() guarantees we have funds here to send
			uint256 _after = IERC20(underlyingContract).balanceOf(farmBoss);
			uint256 _total = _after.sub(_before);

			ACTIVELY_FARMED = ACTIVELY_FARMED.add(_total);

			emit Rebalance(0, _amountChange, block.timestamp);
		}
	}

	function _getTotalUnderlying() internal override view returns (uint256) {
		uint256 _balanceHere = IERC20(underlyingContract).balanceOf(address(this));
		uint256 _balanceFarmed = ACTIVELY_FARMED;

		return _balanceHere.add(_balanceFarmed);
	}

	function rescue(address _token, uint256 _amount) external {
        require(msg.sender == governance, "FARMTREASURYV1: !governance");

        if (_token != address(0)){
            IERC20(_token).safeTransfer(governance, _amount);
        }
        else { // if _tokenContract is 0x0, then escape ETH
            governance.transfer(_amount);
        }
    }
}